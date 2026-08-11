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

//! Contract tests for the detection path.
//!
//! Two invariants, tested together because they are halves of one story:
//!
//! - the image is never rectified twice. It used to be undistorted by the node
//!   and again inside the detector, displacing every corner by roughly the size
//!   of the lens correction itself.
//! - corners are refined to sub-pixel accuracy. OpenCV's default is
//!   `CORNER_REFINE_NONE`, which quantises them to the pixel grid.
//!
//! The contract: `detect` consumes a **raw (distorted)** image, refines corners
//! on those unresampled pixels, and returns them in the **rectified** frame.
//! `rectify()` exists only to produce a debug overlay.
//!
//! The central test is a round trip — render a marker whose corners are exactly
//! known, push it through a known `K, D` to synthesize the distorted image the
//! camera would have delivered, detect, and require the corners to come back
//! where they started. That closes both bugs at once: it fails if the image is
//! rectified twice, if `undistortPoints` is misconfigured, or if refinement is
//! off.

use anyhow::Result;
use golfcart_aruco_detector::{
    detector::validate_distortion, render, ArucoDictionary, BoardGeometry, CornerRefinement,
    Detector, DetectorParams,
};
use nalgebra::Point2;
use opencv::{
    calib3d,
    core::{self as core_cv, Mat, Point2f, Scalar, BORDER_CONSTANT},
    imgproc,
    prelude::*,
};

/// Strong barrel distortion. Big enough that mishandling it is unmissable.
const DISTORTION: [f64; 5] = [-0.25, 0.08, 0.0, 0.0, 0.0];
const NO_DISTORTION: [f64; 5] = [0.0; 5];

/// A rational-polynomial lens: k1 k2 p1 p2 k3 k4 k5 k6, then four thin-prism
/// terms making a 12-coefficient vector. The k4-k6 denominator is what
/// distinguishes this model from plumb_bob, so it is deliberately non-zero and
/// large enough that dropping it is unmissable.
const RATIONAL_12: [f64; 12] = [
    -0.32, 0.14, 0.0, 0.0, -0.03, 0.11, -0.05, 0.01, 0.0, 0.0, 0.0, 0.0,
];

const MARKER_ID: u32 = 696;
const QUIET_ZONE_PX: i32 = 60;

fn geometry() -> BoardGeometry {
    BoardGeometry {
        dictionary: ArucoDictionary::DICT_5X5_1000,
        marker_size_m: 0.384,
        border_bits: 1,
    }
}

fn params(method: CornerRefinement) -> DetectorParams {
    let mut params = DetectorParams::default();
    params.corner_refinement.method = method;
    params
}

/// Render the marker with its quiet zone. `size_px` sets the apparent size.
fn marker_image(size_px: i32) -> Result<Mat> {
    render::render_marker(
        ArucoDictionary::DICT_5X5_1000,
        MARKER_ID,
        size_px,
        1,
        QUIET_ZONE_PX,
    )
}

/// The marker placed away from the principal point, on a wide canvas.
///
/// Distortion is radius-dependent, so a marker centred on the optical axis
/// barely moves however wrong the model is. Any test about the *magnitude* of a
/// distortion error has to put the marker where the lens actually acts, which is
/// also where the real observations are: a wide-field camera sees its boards
/// toward the edge of frame.
fn marker_off_axis(size_px: i32) -> Result<Mat> {
    let canvas = render::blank(1900, 1000)?;
    let marker = render::render_marker(ArucoDictionary::DICT_5X5_1000, MARKER_ID, size_px, 1, 0)?;
    let mut roi = Mat::roi(
        &canvas,
        core_cv::Rect::new(120, 120, marker.cols(), marker.rows()),
    )?;
    marker.copy_to(&mut roi)?;
    Ok(canvas)
}

fn intrinsics(image: &Mat) -> [f64; 9] {
    let (w, h) = (image.cols() as f64, image.rows() as f64);
    [900.0, 0.0, w / 2.0, 0.0, 900.0, h / 2.0, 0.0, 0.0, 1.0]
}

fn detector(image: &Mat, distortion: &[f64], params: DetectorParams) -> Result<Detector> {
    let model = if distortion.len() > 5 {
        "rational_polynomial"
    } else {
        "plumb_bob"
    };
    Detector::new(geometry(), params, &intrinsics(image), distortion, model)
}

/// Flatten a detection into `(id, x, y)` per corner.
fn corners_of(detector: &Detector, image: &Mat) -> Result<Vec<(u32, f32, f32)>> {
    let detections = detector.detect(image)?;
    assert_eq!(
        detections.len(),
        1,
        "expected exactly one marker, found {}",
        detections.len()
    );
    Ok(detections[0]
        .corners
        .iter()
        .map(|c| (detections[0].id, c.x, c.y))
        .collect())
}

/// Synthesize the distorted image that `ideal` would have produced through
/// `K, D`.
///
/// `remap` samples `src` at `map(dst)`, so for each pixel of the distorted
/// output we need its coordinate in the ideal image — which is precisely
/// `undistortPoints`. That is the same primitive the detector uses, run in the
/// opposite direction, so the round trip is exact rather than approximate.
fn distort_image(ideal: &Mat, k: &[f64; 9], d: &[f64]) -> Result<Mat> {
    let (w, h) = (ideal.cols(), ideal.rows());
    let camera_matrix = Mat::from_slice(k)?.reshape(1, 3)?.try_clone()?;
    let distortion = Mat::from_slice(d)?.try_clone()?;
    let eye = Mat::eye(3, 3, core_cv::CV_64FC1)?.to_mat()?;

    let grid: Vec<Point2f> = (0..h)
        .flat_map(|y| (0..w).map(move |x| Point2f::new(x as f32, y as f32)))
        .collect();
    let grid = Mat::from_slice(&grid)?;

    let mut ideal_coords = Mat::default();
    calib3d::undistort_points(
        &grid,
        &mut ideal_coords,
        &camera_matrix,
        &distortion,
        &eye,
        &camera_matrix,
    )?;

    let map = ideal_coords.reshape(2, h)?;
    let mut distorted = Mat::default();
    imgproc::remap(
        ideal,
        &mut distorted,
        &map,
        &core_cv::no_array(),
        imgproc::INTER_LINEAR,
        BORDER_CONSTANT,
        Scalar::new(255.0, 255.0, 255.0, 0.0),
    )?;

    Ok(distorted)
}

fn rmse(a: &[(u32, f32, f32)], b: &[(u32, f32, f32)]) -> f64 {
    assert_eq!(a.len(), b.len());
    let sum_sq: f64 = a
        .iter()
        .zip(b)
        .map(|((id_a, ax, ay), (id_b, bx, by))| {
            assert_eq!(id_a, id_b, "corner lists are not for the same marker");
            let (dx, dy) = ((ax - bx) as f64, (ay - by) as f64);
            dx * dx + dy * dy
        })
        .sum();
    (sum_sq / a.len() as f64).sqrt()
}

// ── the detection path ──────────────────────────────────────────────────────

/// The headline test: corners survive a full distort → detect → undistort round
/// trip.
///
/// Ground truth is the corner set detected on the ideal render. We synthesize
/// what a strongly distorting lens would have delivered, hand that raw frame to
/// the detector, and require the corners it reports to land back on the ideal
/// ones.
///
/// Fails if the image is rectified twice, if `undistortPoints` is called
/// without `P = K` (returning normalized coordinates), or if the corners are
/// never mapped back at all.
#[test]
fn corners_survive_the_distort_detect_undistort_round_trip() -> Result<()> {
    let ideal = marker_image(300)?;
    let subpix = params(CornerRefinement::Subpix);

    let truth = corners_of(&detector(&ideal, &NO_DISTORTION, subpix)?, &ideal)?;
    assert_eq!(truth.len(), 4);

    let distorted = distort_image(&ideal, &intrinsics(&ideal), &DISTORTION)?;
    let recovered = corners_of(&detector(&ideal, &DISTORTION, subpix)?, &distorted)?;

    let err = rmse(&truth, &recovered);
    assert!(
        err < 1.0,
        "corners did not survive the round trip: {err:.3} px RMSE. \
         The lens correction is being applied wrongly (twice, not at all, or in the wrong space)."
    );
    Ok(())
}

/// Sub-pixel refinement must actually be running.
///
/// The second assertion is the important one: without it the first could pass
/// simply because the test is insensitive.
#[test]
fn subpix_refinement_beats_no_refinement() -> Result<()> {
    // A sub-pixel shift is what refinement is for; with the marker on exact
    // pixel boundaries there is nothing to recover. An odd size lands the
    // corners off-grid.
    let ideal = marker_image(287)?;

    let refined = corners_of(
        &detector(&ideal, &NO_DISTORTION, params(CornerRefinement::Subpix))?,
        &ideal,
    )?;
    let unrefined = corners_of(
        &detector(&ideal, &NO_DISTORTION, params(CornerRefinement::None))?,
        &ideal,
    )?;

    let delta = rmse(&refined, &unrefined);
    assert!(
        delta > 0.05,
        "SUBPIX and NONE produced the same corners ({delta:.4} px apart), \
         so corner refinement is not running at all"
    );
    Ok(())
}

/// With zero distortion `undistortPoints` must be an identity, so the corners
/// reported are the ones measured, unmoved.
///
/// This guards against a `P`-less `undistortPoints`, which returns *normalized*
/// coordinates (order 1e-1) instead of pixels (order 1e2) — catastrophically
/// wrong even when `D` is zero.
#[test]
fn zero_distortion_leaves_corners_in_pixel_coordinates() -> Result<()> {
    let ideal = marker_image(300)?;
    let det = detector(&ideal, &NO_DISTORTION, params(CornerRefinement::Subpix))?;
    let corners = corners_of(&det, &ideal)?;

    let (w, h) = (ideal.cols() as f32, ideal.rows() as f32);
    for (id, x, y) in &corners {
        assert!(
            *x > 1.0 && *x < w && *y > 1.0 && *y < h,
            "marker {id} corner ({x}, {y}) is not a pixel coordinate in a {w}x{h} image; \
             undistortPoints was likely called without P = K"
        );
    }
    Ok(())
}

/// `win_size = 5` must hold across the working marker size range.
///
/// The window has to stay well under half the corner spacing, or adjacent
/// corners' windows overlap and pull each other off-target. Refinement should
/// nudge corners, not fling them.
#[test]
fn default_win_size_holds_across_the_working_marker_size_range() -> Result<()> {
    // ~300 px at 1.5 m down to ~60 px at 6 m.
    for size_px in [300, 200, 100, 60] {
        let ideal = marker_image(size_px)?;

        let refined = corners_of(
            &detector(&ideal, &NO_DISTORTION, params(CornerRefinement::Subpix))?,
            &ideal,
        )?;
        let unrefined = corners_of(
            &detector(&ideal, &NO_DISTORTION, params(CornerRefinement::None))?,
            &ideal,
        )?;

        let delta = rmse(&refined, &unrefined);
        assert!(
            delta < 3.0,
            "at {size_px} px, SUBPIX moved corners {delta:.3} px from the unrefined estimate; \
             win_size=5 is likely spanning adjacent corners at this marker size"
        );
    }
    Ok(())
}

/// `rectify()` is overlay-only, but must still be correct: rectifying a
/// distorted image has to put the marker back where the ideal render has it, or
/// the debug overlay disagrees with the corners the solver consumes.
#[test]
fn rectify_undoes_the_distortion_for_the_overlay() -> Result<()> {
    let ideal = marker_image(300)?;
    let subpix = params(CornerRefinement::Subpix);

    let distorted = distort_image(&ideal, &intrinsics(&ideal), &DISTORTION)?;
    let rectified = detector(&ideal, &DISTORTION, subpix)?.rectify(&distorted)?;

    let on_rectified = corners_of(&detector(&ideal, &NO_DISTORTION, subpix)?, &rectified)?;
    let truth = corners_of(&detector(&ideal, &NO_DISTORTION, subpix)?, &ideal)?;

    let err = rmse(&truth, &on_rectified);
    assert!(
        err < 2.0,
        "rectify() did not undo the distortion: {err:.3} px RMSE"
    );
    Ok(())
}

// ── distortion models ───────────────────────────────────────────────────────

/// A 12-coefficient `rational_polynomial` camera survives the same round trip.
///
/// The wide lenses this system uses publish 8 or 12 coefficients. Truncating to
/// five does not fail loudly — it bends every corner near the image edge, which
/// is exactly where the wide-field observations live.
#[test]
fn rational_polynomial_corners_survive_the_round_trip() -> Result<()> {
    let ideal = marker_image(300)?;
    let subpix = params(CornerRefinement::Subpix);

    let truth = corners_of(&detector(&ideal, &NO_DISTORTION, subpix)?, &ideal)?;
    let distorted = distort_image(&ideal, &intrinsics(&ideal), &RATIONAL_12)?;
    let recovered = corners_of(&detector(&ideal, &RATIONAL_12, subpix)?, &distorted)?;

    let err = rmse(&truth, &recovered);
    assert!(
        err < 1.0,
        "rational_polynomial corners did not survive the round trip: {err:.3} px RMSE. \
         The k4-k6 denominator is most likely being dropped."
    );
    Ok(())
}

/// Truncating a rational-polynomial `D` to five coefficients must not be
/// mistaken for a harmless simplification. Asserting the damage is large is
/// what justifies carrying all the coefficients; if this stops holding, the
/// test coefficients have gone slack.
#[test]
fn truncating_the_rational_denominator_moves_corners_a_lot() -> Result<()> {
    // Off-axis, because that is where the difference between the two models
    // lives. A centred marker moves by almost nothing no matter how wrong the
    // model is, which would make this test pass for the wrong reason.
    let ideal = marker_off_axis(260)?;
    let subpix = params(CornerRefinement::Subpix);

    let distorted = distort_image(&ideal, &intrinsics(&ideal), &RATIONAL_12)?;
    let correct = corners_of(&detector(&ideal, &RATIONAL_12, subpix)?, &distorted)?;

    let truncated_d: Vec<f64> = RATIONAL_12[..5].to_vec();
    let truncated = corners_of(&detector(&ideal, &truncated_d, subpix)?, &distorted)?;

    let delta = rmse(&correct, &truncated);
    assert!(
        delta > 5.0,
        "dropping k4-k6 moved corners only {delta:.3} px, so these test coefficients \
         no longer exercise the rational denominator"
    );
    Ok(())
}

/// The declared model and the coefficient count must agree. OpenCV picks the
/// distortion function from the length of `D` alone and never reads the model
/// name, so a mismatch is otherwise silent.
#[test]
fn a_mislabelled_distortion_model_is_rejected() -> Result<()> {
    let ideal = marker_image(300)?;
    let result = Detector::new(
        geometry(),
        params(CornerRefinement::Subpix),
        &intrinsics(&ideal),
        &RATIONAL_12,
        "plumb_bob",
    );
    assert!(
        result.is_err(),
        "a 12-coefficient camera declaring plumb_bob was accepted; \
         OpenCV would silently apply the rational model to it"
    );
    assert!(validate_distortion("plumb_bob", 12).is_err());
    Ok(())
}

// ── detection semantics ─────────────────────────────────────────────────────

/// Whatever is in view gets reported, not only a configured set.
///
/// LCTK's detector returns nothing unless the detected IDs exactly equal the
/// configured ones, which is right for calibrating against a known board and
/// wrong here: the vehicle sees whichever markers the room presents, and
/// refusing a frame because one is occluded would discard every usable
/// observation. That mode was dropped in the merge; this pins its absence.
#[test]
fn every_marker_in_view_is_reported() -> Result<()> {
    let canvas_w = 1400;
    let canvas_h = 700;
    let canvas = render::blank(canvas_w, canvas_h)?;

    let ids = [696u32, 64, 306];
    for (index, &id) in ids.iter().enumerate() {
        let marker = render::render_marker(ArucoDictionary::DICT_5X5_1000, id, 220, 1, 0)?;
        let x = 90 + index as i32 * 420;
        let mut roi = Mat::roi(&canvas, core_cv::Rect::new(x, 240, marker.cols(), marker.rows()))?;
        marker.copy_to(&mut roi)?;
    }

    let det = detector(&canvas, &NO_DISTORTION, params(CornerRefinement::Subpix))?;
    let detections = det.detect(&canvas)?;

    let mut found: Vec<u32> = detections.iter().map(|d| d.id).collect();
    found.sort_unstable();
    let mut expected = ids.to_vec();
    expected.sort_unstable();
    assert_eq!(
        found, expected,
        "expected every marker in view to be reported"
    );
    Ok(())
}

/// An empty frame is not an error. The localizer distinguishes a coverage gap
/// from a detector that has stopped running, and can only do that if "nothing
/// in view" comes back as an empty result rather than a failure.
#[test]
fn an_empty_frame_yields_no_detections_and_no_error() -> Result<()> {
    let blank = render::blank(640, 480)?;
    let det = detector(&blank, &NO_DISTORTION, params(CornerRefinement::Subpix))?;
    assert!(det.detect(&blank)?.is_empty());
    Ok(())
}

/// Corner order is a contract between the detector and everything downstream.
///
/// The localizer solves jointly over corners and pairs each pixel with a fixed
/// point in the marker frame. If this order changed, every pose would come back
/// rotated about the marker normal — a failure that presents as a calibration
/// error rather than an indexing one.
#[test]
fn corners_are_reported_clockwise_from_top_left() -> Result<()> {
    let ideal = marker_image(300)?;
    let det = detector(&ideal, &NO_DISTORTION, params(CornerRefinement::Subpix))?;
    let corners = det.detect(&ideal)?[0].corners;

    let centroid = corners
        .iter()
        .fold(Point2::new(0.0f32, 0.0f32), |acc, c| {
            Point2::new(acc.x + c.x / 4.0, acc.y + c.y / 4.0)
        });

    // Image coordinates: +x right, +y DOWN. Top-left is therefore the corner
    // that is left of and above the centroid.
    let expected_signs = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)];
    let names = ["top-left", "top-right", "bottom-right", "bottom-left"];
    for (i, ((sx, sy), name)) in expected_signs.iter().zip(names).enumerate() {
        let dx = (corners[i].x - centroid.x) as f64;
        let dy = (corners[i].y - centroid.y) as f64;
        assert!(
            dx * sx > 0.0 && dy * sy > 0.0,
            "corner {i} was expected to be the {name} one, but sits at \
             ({dx:+.1}, {dy:+.1}) relative to the marker centre"
        );
    }
    Ok(())
}
