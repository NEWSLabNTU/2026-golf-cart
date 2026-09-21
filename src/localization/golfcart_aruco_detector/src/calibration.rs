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

//! Reconciling a frame against the calibration that claims to describe it.
//!
//! `k` is in pixels of one particular image size, and `CameraInfo` states that
//! size in its own `width` and `height`. When the two disagree the poses do not
//! become noisy, they become wrong by a constant factor and stay
//! self-consistent, which is the hardest kind of error to notice downstream: a
//! localizer fed them does not see bad data, it sees a vehicle somewhere else.
//!
//! The way it happens is ordinary. Someone changes the capture resolution in a
//! camera profile and does not recalibrate. gmslcam publishes the calibration
//! file verbatim -- it replaces only the header -- so the stale size travels
//! with the stale intrinsics, and that stale size is the evidence.
//!
//! Kept here, away from the node, because it is a decision about numbers: no
//! logging, no ROS types, no rebuilding of anything. The node decides what to
//! *do*; this decides what is *true*.

/// What to do with a frame, given the size the calibration was made for.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum FrameSize {
    /// The frame is the size the intrinsics describe. Detect normally.
    Matches,
    /// Same shape, different size, and rescaling was permitted. Multiply the
    /// intrinsics by this factor -- it is `expected / actual`, which is what
    /// [`crate::scale_intrinsics`] takes.
    Rescale { factor: f64 },
    /// Same shape, different size, and rescaling was not permitted.
    SizeMismatch,
    /// Different shape. Never rescaled, however the flags are set: this is not
    /// a resolution change but a different sensor mode or the wrong calibration
    /// file, and scaling intrinsics to fit it moves the poses further from the
    /// truth rather than closer.
    AspectMismatch,
    /// The calibration declares a zero dimension, so there is nothing to
    /// compare against. An unpopulated `CameraInfo` looks like this.
    Unusable,
}

/// A percent of slack on the aspect ratio.
///
/// Enough to absorb the rounding an odd dimension produces -- 1919x1280 against
/// 1920x1280 is the same camera -- and not enough to let 4:3 pass as 3:2.
const ASPECT_TOLERANCE: f64 = 0.01;

/// Decide what a frame of `actual` size means for a calibration made at
/// `expected` size.
///
/// Both are `(width, height)`. `expected` is what `CameraInfo` declared, already
/// divided by any decode scaling the node applies, so that both describe the
/// image the detector will actually see.
pub fn reconcile_frame_size(
    expected: (u32, u32),
    actual: (u32, u32),
    allow_rescale: bool,
) -> FrameSize {
    if expected.0 == 0 || expected.1 == 0 || actual.0 == 0 || actual.1 == 0 {
        return FrameSize::Unusable;
    }
    if expected == actual {
        return FrameSize::Matches;
    }

    let expected_ratio = expected.0 as f64 / expected.1 as f64;
    let actual_ratio = actual.0 as f64 / actual.1 as f64;
    if (expected_ratio - actual_ratio).abs() / expected_ratio >= ASPECT_TOLERANCE {
        return FrameSize::AspectMismatch;
    }

    if !allow_rescale {
        return FrameSize::SizeMismatch;
    }

    FrameSize::Rescale {
        factor: expected.0 as f64 / actual.0 as f64,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scale_intrinsics;

    const FULL: (u32, u32) = (1920, 1280);

    #[test]
    fn the_expected_size_is_the_normal_case() {
        assert_eq!(
            reconcile_frame_size(FULL, FULL, false),
            FrameSize::Matches
        );
        // The flag changes nothing when there is nothing to reconcile.
        assert_eq!(reconcile_frame_size(FULL, FULL, true), FrameSize::Matches);
    }

    #[test]
    fn a_smaller_frame_of_the_same_shape_is_refused_by_default() {
        assert_eq!(
            reconcile_frame_size(FULL, (960, 640), false),
            FrameSize::SizeMismatch
        );
    }

    #[test]
    fn a_smaller_frame_of_the_same_shape_rescales_when_allowed() {
        assert_eq!(
            reconcile_frame_size(FULL, (960, 640), true),
            FrameSize::Rescale { factor: 2.0 }
        );
        // And in the other direction: a frame LARGER than the calibration
        // scales by less than one rather than being treated as a special case.
        assert_eq!(
            reconcile_frame_size(FULL, (3840, 2560), true),
            FrameSize::Rescale { factor: 0.5 }
        );
    }

    #[test]
    fn a_different_shape_is_refused_however_the_flag_is_set() {
        // 4:3 against 3:2. This is the case where rescaling would be actively
        // harmful, so the flag must not reach it.
        for allow in [false, true] {
            assert_eq!(
                reconcile_frame_size(FULL, (1280, 960), allow),
                FrameSize::AspectMismatch,
                "allow_rescale = {allow}"
            );
        }
    }

    #[test]
    fn rounding_on_an_odd_dimension_is_not_a_different_shape() {
        // 1919x1280 is 1920x1280 with a pixel shaved off. Refusing it as an
        // aspect mismatch would be a false alarm on a real camera.
        assert_eq!(
            reconcile_frame_size(FULL, (1919, 1280), false),
            FrameSize::SizeMismatch
        );
        assert!(matches!(
            reconcile_frame_size(FULL, (1919, 1280), true),
            FrameSize::Rescale { .. }
        ));
    }

    #[test]
    fn an_unpopulated_camera_info_is_unusable_rather_than_a_division_by_zero() {
        // sensor_msgs/CameraInfo defaults to zeros, and a driver that publishes
        // before loading its calibration sends exactly this. Computing an
        // aspect ratio from it yields NaN, and NaN compares false against every
        // threshold, so it would have sailed through as "same shape".
        assert_eq!(
            reconcile_frame_size((0, 0), FULL, false),
            FrameSize::Unusable
        );
        assert_eq!(
            reconcile_frame_size(FULL, (0, 0), true),
            FrameSize::Unusable
        );
        assert_eq!(
            reconcile_frame_size((1920, 0), FULL, true),
            FrameSize::Unusable
        );
    }

    #[test]
    fn the_rescale_factor_is_the_one_scale_intrinsics_wants() {
        // The contract between this module and the node: whatever factor comes
        // back, feeding it to scale_intrinsics must produce intrinsics for the
        // frame that was actually received. Checked by the principal point,
        // which should land at the centre of the new frame when it was at the
        // centre of the old one.
        let k = [1000.0, 0.0, 959.5, 0.0, 1000.0, 639.5, 0.0, 0.0, 1.0];
        let actual = (960u32, 640u32);
        let FrameSize::Rescale { factor } = reconcile_frame_size(FULL, actual, true) else {
            panic!("expected a rescale");
        };
        let scaled = scale_intrinsics(&k, factor);
        assert!((scaled[2] - (actual.0 as f64 / 2.0 - 0.5)).abs() < 1e-9, "cx {}", scaled[2]);
        assert!((scaled[5] - (actual.1 as f64 / 2.0 - 0.5)).abs() < 1e-9, "cy {}", scaled[5]);
        assert!((scaled[0] - 500.0).abs() < 1e-9, "fx {}", scaled[0]);
    }

    #[test]
    fn the_decode_scale_is_applied_before_the_comparison() {
        // The node divides the declared size by image_decode_scale before
        // calling this, so decoding a 1920x1280 stream at half must compare as
        // a match against a 960x640 frame rather than as a mismatch. Pinned
        // here because getting it wrong makes every scaled-decode run refuse to
        // detect anything, which reads as a broken camera.
        let declared = (1920u32, 1280u32);
        let decode_scale = 2u32;
        let expected = (declared.0 / decode_scale, declared.1 / decode_scale);
        assert_eq!(
            reconcile_frame_size(expected, (960, 640), false),
            FrameSize::Matches
        );
    }
}
