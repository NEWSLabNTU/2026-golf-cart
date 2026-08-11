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

//! Detector tuning, and the one place OpenCV's `DetectorParameters` is built.
//!
//! Vendored from LCTK's `aruco-config`. `L-11` there was a copy-pasted block
//! that set `adaptive_thresh_win_size_step` twice and tuned a refiner that was
//! never enabled; keeping construction in a single validated function is what
//! prevents that recurring.

use anyhow::{ensure, Result};
use opencv::{aruco, core::Ptr, prelude::*};
use serde::{Deserialize, Serialize};

/// How `detectMarkers` localises the marker corners.
///
/// OpenCV's default is [`CornerRefinement::None`], which returns the raw quad
/// intersections quantised to roughly the pixel grid. That is LCTK's `H-08`
/// bug, and it matters more here than it looks: corner localisation error is
/// the direct input noise of the pose solve, and with four corners per marker
/// there is no redundancy to average it away.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CornerRefinement {
    /// No refinement. OpenCV's default.
    None,
    /// Iterative gradient search (`cornerSubPix`) in a window around each
    /// corner. Measured by LCTK to beat no refinement by 25-60 % at every
    /// apparent marker size from 54 px to 302 px.
    #[default]
    Subpix,
    /// Fit lines to the marker contour and intersect adjacent sides. Measured
    /// equal or worse than `Subpix`, but has no window to tune, so it degrades
    /// more gracefully on small or motion-blurred markers.
    Contour,
}

impl CornerRefinement {
    fn to_opencv(self) -> i32 {
        let method = match self {
            Self::None => aruco::CornerRefineMethod::CORNER_REFINE_NONE,
            Self::Subpix => aruco::CornerRefineMethod::CORNER_REFINE_SUBPIX,
            Self::Contour => aruco::CornerRefineMethod::CORNER_REFINE_CONTOUR,
        };
        method as i32
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CornerRefinementParams {
    pub method: CornerRefinement,
    /// Half-width of the `cornerSubPix` search window, in pixels.
    ///
    /// Must stay well under half the spacing between two corners of the same
    /// marker, or adjacent corners' windows overlap and pull each other
    /// off-target. A 0.384 m marker spans roughly 200 px at 1.5 m and 35 px at
    /// 6 m, so 5 is safe across the working range — pinned by a test.
    pub win_size: i32,
    pub max_iterations: i32,
    pub min_accuracy: f64,
}

impl Default for CornerRefinementParams {
    fn default() -> Self {
        Self {
            method: CornerRefinement::default(),
            win_size: 5,
            max_iterations: 30,
            min_accuracy: 0.01,
        }
    }
}

/// Adaptive-threshold sweep used to find marker candidates.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AdaptiveThreshParams {
    pub win_size_min: i32,
    pub win_size_max: i32,
    pub win_size_step: i32,
}

impl Default for AdaptiveThreshParams {
    fn default() -> Self {
        Self {
            win_size_min: 13,
            win_size_max: 33,
            win_size_step: 10,
        }
    }
}

/// Candidate filtering, applied before a quad is ever decoded.
///
/// OpenCV's defaults are tuned for markers filling a good part of the frame.
/// An indoor localization scene is the opposite case — small markers, far away,
/// several in one image — and the defaults reject exactly those.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct CandidateFilterParams {
    /// Smallest accepted marker perimeter, as a fraction of the larger image
    /// dimension. OpenCV's 0.03 discards a marker below roughly 14 px per side
    /// on a 1920-wide image, which is inside the range this system needs.
    pub min_marker_perimeter_rate: f64,
    pub max_marker_perimeter_rate: f64,
    /// Fraction of the dictionary's error-correction capacity usable when
    /// decoding. Higher accepts more damaged markers at the cost of false IDs.
    ///
    /// Stays at OpenCV's 0.6 rather than being raised to chase detections: a
    /// false ID is associated to a real surveyed pose and yields a confident
    /// wrong answer, which is worse than the missing observation.
    pub error_correction_rate: f64,
    /// Minimum distance between two candidates, as a fraction of perimeter.
    /// Markers legitimately appear close together when several boards are seen
    /// at an angle.
    pub min_marker_distance_rate: f64,
}

impl Default for CandidateFilterParams {
    fn default() -> Self {
        Self {
            // Admits a ~5 px-per-side marker on a 1920-wide image, which is past
            // being decodable — the intent is that the decoder rejects it, not
            // the perimeter filter.
            min_marker_perimeter_rate: 0.01,
            max_marker_perimeter_rate: 4.0,
            error_correction_rate: 0.6,
            min_marker_distance_rate: 0.05,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DetectorParams {
    pub corner_refinement: CornerRefinementParams,
    pub adaptive_thresh: AdaptiveThreshParams,
    pub candidate_filter: CandidateFilterParams,
}

impl DetectorParams {
    /// Build OpenCV's `DetectorParameters`. The ONE place this happens.
    ///
    /// Validation lives here and runs at detector construction rather than per
    /// frame, so a bad configuration fails at startup instead of silently every
    /// frame thereafter.
    pub fn to_opencv(&self, border_bits: i32) -> Result<Ptr<aruco::DetectorParameters>> {
        let Self {
            corner_refinement,
            adaptive_thresh,
            candidate_filter,
        } = *self;

        ensure!(
            corner_refinement.win_size >= 1,
            "corner_refinement.win_size must be >= 1, got {}",
            corner_refinement.win_size
        );
        ensure!(
            adaptive_thresh.win_size_min >= 3
                && adaptive_thresh.win_size_max >= adaptive_thresh.win_size_min
                && adaptive_thresh.win_size_step >= 1,
            "adaptive_thresh must satisfy 3 <= win_size_min <= win_size_max and win_size_step >= 1"
        );
        ensure!(
            candidate_filter.min_marker_perimeter_rate > 0.0
                && candidate_filter.max_marker_perimeter_rate
                    > candidate_filter.min_marker_perimeter_rate,
            "candidate_filter must satisfy 0 < min_marker_perimeter_rate < max_marker_perimeter_rate"
        );
        ensure!(
            (0.0..=1.0).contains(&candidate_filter.error_correction_rate),
            "candidate_filter.error_correction_rate must be in [0, 1], got {}",
            candidate_filter.error_correction_rate
        );
        ensure!(
            candidate_filter.min_marker_distance_rate >= 0.0,
            "candidate_filter.min_marker_distance_rate must be >= 0, got {}",
            candidate_filter.min_marker_distance_rate
        );
        ensure!(border_bits >= 1, "border_bits must be >= 1, got {border_bits}");

        let mut params = aruco::DetectorParameters::create()?;
        params.set_marker_border_bits(border_bits);

        params.set_adaptive_thresh_win_size_min(adaptive_thresh.win_size_min);
        params.set_adaptive_thresh_win_size_max(adaptive_thresh.win_size_max);
        params.set_adaptive_thresh_win_size_step(adaptive_thresh.win_size_step);

        params.set_corner_refinement_method(corner_refinement.method.to_opencv());
        params.set_corner_refinement_win_size(corner_refinement.win_size);
        params.set_corner_refinement_max_iterations(corner_refinement.max_iterations);
        params.set_corner_refinement_min_accuracy(corner_refinement.min_accuracy);

        params.set_min_marker_perimeter_rate(candidate_filter.min_marker_perimeter_rate);
        params.set_max_marker_perimeter_rate(candidate_filter.max_marker_perimeter_rate);
        params.set_error_correction_rate(candidate_filter.error_correction_rate);
        params.set_min_marker_distance_rate(candidate_filter.min_marker_distance_rate);

        Ok(params)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_accepted() {
        assert!(DetectorParams::default().to_opencv(1).is_ok());
    }

    #[test]
    fn a_bad_adaptive_thresh_sweep_is_rejected_at_construction() {
        let mut params = DetectorParams::default();
        params.adaptive_thresh.win_size_max = 3;
        params.adaptive_thresh.win_size_min = 33;
        assert!(params.to_opencv(1).is_err());
    }

    #[test]
    fn an_error_correction_rate_outside_zero_to_one_is_rejected() {
        let mut params = DetectorParams::default();
        params.candidate_filter.error_correction_rate = 1.5;
        assert!(params.to_opencv(1).is_err());
    }
}
