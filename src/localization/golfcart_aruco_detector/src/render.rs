// Copyright 2026 Golf Cart Team
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Rendering a marker, for tests and for eyeballing a board.
//!
//! LCTK's generator lays markers out on a printable grid because it produces the
//! physical targets. This system's boards are already printed and surveyed, so
//! all that is needed here is a single marker with a quiet zone — enough to
//! synthesize an image the detector can be tested against.

use crate::dictionary::ArucoDictionary;
use anyhow::{ensure, Result};
use opencv::{
    core::{self as core_cv, Mat, Scalar, BORDER_CONSTANT, CV_8UC1},
    prelude::*,
};

/// Render one marker, white quiet zone included.
///
/// The quiet zone is not decoration: `detectMarkers` finds candidates by
/// thresholding and contour-following, and a marker running to the edge of the
/// image has no contour to find. Rendering without it produces an image the
/// detector cannot see, which reads as a detector bug.
pub fn render_marker(
    dictionary: ArucoDictionary,
    id: u32,
    marker_size_px: i32,
    border_bits: i32,
    quiet_zone_px: i32,
) -> Result<Mat> {
    ensure!(marker_size_px > 0, "marker_size_px must be positive");
    ensure!(quiet_zone_px >= 0, "quiet_zone_px must be non-negative");

    let opencv_dictionary = dictionary.to_opencv()?;
    let mut marker = Mat::default();
    opencv_dictionary.draw_marker(id as i32, marker_size_px, &mut marker, border_bits)?;

    if quiet_zone_px == 0 {
        return Ok(marker);
    }

    let mut padded = Mat::default();
    core_cv::copy_make_border(
        &marker,
        &mut padded,
        quiet_zone_px,
        quiet_zone_px,
        quiet_zone_px,
        quiet_zone_px,
        BORDER_CONSTANT,
        Scalar::new(255.0, 255.0, 255.0, 0.0),
    )?;
    Ok(padded)
}

/// A blank white canvas, for compositing markers onto.
pub fn blank(width: i32, height: i32) -> Result<Mat> {
    Ok(Mat::new_rows_cols_with_default(
        height,
        width,
        CV_8UC1,
        Scalar::new(255.0, 255.0, 255.0, 0.0),
    )?)
}
