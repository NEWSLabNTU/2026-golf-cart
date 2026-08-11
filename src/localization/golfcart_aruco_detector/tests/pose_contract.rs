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

//! Contract tests for per-marker pose recovery.
//!
//! The headline invariant is simple to state and easy to lose: **the pose we
//! report must reproject onto the corners we were given**. On noiseless
//! synthetic corners that error is zero by construction, so anything above a
//! rounding error means the pose is wrong.
//!
//! This matters here more than it usually would, because the obvious
//! implementation — `solvePnPGeneric(SOLVEPNP_IPPE_SQUARE)`, which is what the
//! method exists for — returns poses on OpenCV 4.5.4 that do *not* reproject,
//! by as much as 115 px on a ~1900 px image. `solve_marker_pose` works around
//! that by seeding from two methods, refining with LM, and scoring the results
//! itself. These tests fail if someone simplifies that back to the obvious call.

use anyhow::Result;
use golfcart_aruco_detector::marker_pnp::{
    marker_local_corners, solve_marker_pose, to_isometry, MarkerPose,
};
use nalgebra::{Isometry3, Point2, Translation3, UnitQuaternion, Vector3};
use opencv::{
    calib3d,
    core::{self as core_cv, Mat, Point2f, Point3f, Vector},
    prelude::*,
};

const MARKER_SIZE_M: f64 = 0.384;
const FX: f64 = 900.0;
const FY: f64 = 900.0;
const CX: f64 = 960.0;
const CY: f64 = 640.0;

fn camera_matrix() -> Result<Mat> {
    let k: [f64; 9] = [FX, 0.0, CX, 0.0, FY, CY, 0.0, 0.0, 1.0];
    Ok(Mat::from_slice(&k)?.reshape(1, 3)?.try_clone()?)
}

/// A marker pose in the camera frame: pushed out to `z`, offset sideways, and
/// tilted about its own x axis.
fn marker_at(x: f64, y: f64, z: f64, tilt: f64) -> Isometry3<f64> {
    // Rotated to face the camera (+z of the marker toward -z of the camera),
    // then tilted so the view is oblique.
    let facing = UnitQuaternion::from_axis_angle(&Vector3::y_axis(), std::f64::consts::PI);
    let tilted = facing * UnitQuaternion::from_axis_angle(&Vector3::x_axis(), tilt);
    Isometry3::from_parts(Translation3::new(x, y, z), tilted)
}

/// Project a marker's four corners through the pinhole model. Noiseless, so the
/// true pose reprojects to exactly zero.
fn project(pose: &Isometry3<f64>) -> [Point2<f32>; 4] {
    let object = marker_local_corners(MARKER_SIZE_M);
    let mut out = [Point2::new(0.0f32, 0.0f32); 4];
    for (slot, obj) in out.iter_mut().zip(object.iter()) {
        let c = pose * obj;
        *slot = Point2::new(
            (FX * c.x / c.z + CX) as f32,
            (FY * c.y / c.z + CY) as f32,
        );
    }
    out
}

/// Worst-corner reprojection error of `pose` against `pixels`, in pixels.
fn reprojection_error(pose: &Isometry3<f64>, pixels: &[Point2<f32>; 4]) -> f64 {
    let object = marker_local_corners(MARKER_SIZE_M);
    object
        .iter()
        .zip(pixels)
        .map(|(obj, px)| {
            let c = pose * obj;
            let u = FX * c.x / c.z + CX;
            let v = FY * c.y / c.z + CY;
            ((u - px.x as f64).powi(2) + (v - px.y as f64).powi(2)).sqrt()
        })
        .fold(0.0f64, f64::max)
}

fn solve(pixels: &[Point2<f32>; 4]) -> Result<MarkerPose> {
    solve_marker_pose(pixels, MARKER_SIZE_M, &camera_matrix()?)
}

/// The geometries that matter, including the two that break raw IPPE.
fn geometries() -> Vec<(&'static str, Isometry3<f64>)> {
    vec![
        ("fronto-parallel, centred", marker_at(0.0, 0.0, 3.0, 0.0)),
        ("0.2 rad tilt, off-centre", marker_at(0.6, -0.3, 4.0, 0.2)),
        ("0.5 rad tilt, off-centre", marker_at(-0.8, 0.4, 5.0, 0.5)),
        ("0.9 rad tilt, off-centre", marker_at(1.2, 0.2, 6.0, 0.9)),
    ]
}

/// The headline test. Every geometry, noiseless corners, so the true pose
/// reprojects to zero and anything else is a defect.
///
/// This is what fails if `solve_marker_pose` is simplified back to a bare
/// `solvePnPGeneric(SOLVEPNP_IPPE_SQUARE)`: on OpenCV 4.5.4 the fronto-parallel
/// case comes back 115 px out.
#[test]
fn recovered_pose_reprojects_onto_the_corners_it_was_given() -> Result<()> {
    for (name, truth) in geometries() {
        let pixels = project(&truth);
        let solved = solve(&pixels)?;

        let error = reprojection_error(&solved.pose_1, &pixels);
        assert!(
            error < 1e-3,
            "{name}: the reported pose is {error:.4} px from the corners it was solved from. \
             On noiseless corners this must be zero. Has the LM refinement been dropped?"
        );
    }
    Ok(())
}

/// The reported pose must also be the *right* one, not merely a self-consistent
/// one. A marker is genuinely two-valued, so this checks the better solution is
/// the true pose rather than its twin.
#[test]
fn the_better_solution_is_the_true_pose() -> Result<()> {
    for (name, truth) in geometries() {
        let pixels = project(&truth);
        let solved = solve(&pixels)?;

        let position = (solved.pose_1.translation.vector - truth.translation.vector).norm();
        let rotation = solved.pose_1.rotation.angle_to(&truth.rotation).to_degrees();
        assert!(
            position < 1e-3 && rotation < 1e-1,
            "{name}: recovered pose is {position:.5} m and {rotation:.4} deg from truth"
        );
    }
    Ok(())
}

/// Our own scoring must be at least as good as what OpenCV's IPPE returns
/// unaided.
///
/// Written as a comparison rather than as an assertion about IPPE's absolute
/// error on purpose: if a future OpenCV fixes IPPE, this test keeps passing
/// instead of becoming a false alarm. What it will not tolerate is our path
/// becoming *worse* than the thing it exists to work around.
#[test]
fn we_are_never_worse_than_unaided_ippe() -> Result<()> {
    let object: Vector<Point3f> = marker_local_corners(MARKER_SIZE_M)
        .iter()
        .map(|p| Point3f::new(p.x as f32, p.y as f32, p.z as f32))
        .collect();
    let k = camera_matrix()?;
    let distortion = Mat::zeros(5, 1, core_cv::CV_64FC1)?.to_mat()?;

    for (name, truth) in geometries() {
        let pixels = project(&truth);
        let pixels_cv: Vector<Point2f> = pixels.iter().map(|p| Point2f::new(p.x, p.y)).collect();

        let mut rvecs = Vector::<Mat>::new();
        let mut tvecs = Vector::<Mat>::new();
        let mut errors = Mat::default();
        calib3d::solve_pnp_generic(
            &object,
            &pixels_cv,
            &k,
            &distortion,
            &mut rvecs,
            &mut tvecs,
            false,
            calib3d::SolvePnPMethod::SOLVEPNP_IPPE_SQUARE,
            &core_cv::no_array(),
            &core_cv::no_array(),
            &mut errors,
        )?;

        // Best of what raw IPPE offers, scored the same way we score ours.
        let mut raw_best = f64::MAX;
        for (rvec, tvec) in rvecs.iter().zip(tvecs.iter()) {
            let pose = to_isometry(&rvec, &tvec)?;
            raw_best = raw_best.min(reprojection_error(&pose, &pixels));
        }

        let ours = reprojection_error(&solve(&pixels)?.pose_1, &pixels);
        assert!(
            ours <= raw_best + 1e-6,
            "{name}: our solution ({ours:.4} px) is worse than unaided IPPE ({raw_best:.4} px)"
        );
    }
    Ok(())
}

/// What the ambiguity ratio does **not** tell you.
///
/// Measured here: a 0.384 m marker at 3 m through f=900, with 0.3 px of corner
/// noise, 300 trials per tilt. Median ratio, and median rotation error of the
/// reported pose against truth:
///
/// | tilt | 0 deg | 5 | 10 | 15 | 25 | 45 | 75 |
/// |---|---|---|---|---|---|---|---|
/// | ratio | 0.000 | 0.000 | 0.000 | 0.046 | 0.029 | 0.016 | 0.013 |
/// | rotation error | 1.45 deg | 1.01 | 0.65 | 0.44 | 0.28 | 0.19 | 0.14 |
///
/// Rotation error is worst looking straight at the marker and improves as it
/// tilts, which is the counter-intuitive part everyone expects to be backwards.
/// But the ratio does **not** track it. Below about 10 degrees of tilt the ratio
/// reports 0 -- maximum confidence -- precisely where the orientation is least
/// reliable, because the twin solution is not yet distinct enough to survive as
/// a rival and the metric has nothing to compare against.
///
/// So an ambiguity gate cannot be relied on to exclude near-fronto-parallel
/// views. A minimum *view angle* gate must do that, and the two are not
/// interchangeable. This test pins the behaviour so the gap stays visible
/// instead of being rediscovered in a log.
#[test]
fn the_ratio_does_not_flag_a_fronto_parallel_view() -> Result<()> {
    let pixels = project(&marker_at(0.0, 0.0, 3.0, 0.0));
    let solved = solve(&pixels)?;

    let ratio = solved.ambiguity_ratio();
    assert!(
        ratio < 0.2,
        "the ratio flagged a fronto-parallel view ({ratio:.4}). That would be welcome, \
         but it is not what this metric does -- re-read the measurement above before \
         relaxing any view-angle gate on the strength of it."
    );
    Ok(())
}

/// Rotation accuracy must improve as the marker tilts away from fronto-parallel.
///
/// This is the relationship the view-angle gate is built on, and it is the one
/// that actually protects the pose. Pinned separately from the ratio because,
/// per the measurement above, the ratio does not carry it.
#[test]
fn orientation_accuracy_improves_with_obliquity() -> Result<()> {
    let flat = marker_at(0.0, 0.0, 3.0, 0.0);
    let tilted = marker_at(0.0, 0.0, 3.0, 45f64.to_radians());

    // One corner nudged by a realistic fraction of a pixel, same perturbation in
    // both geometries, so the only variable is the viewing angle.
    let perturb = |pose: &Isometry3<f64>| -> Result<f64> {
        let mut pixels = project(pose);
        pixels[0].x += 0.3;
        pixels[2].y -= 0.3;
        let solved = solve(&pixels)?;
        Ok(solved.pose_1.rotation.angle_to(&pose.rotation).to_degrees())
    };

    let flat_error = perturb(&flat)?;
    let tilted_error = perturb(&tilted)?;
    assert!(
        tilted_error < flat_error,
        "a tilted marker ({tilted_error:.3} deg) did not orient better than a \
         fronto-parallel one ({flat_error:.3} deg) under the same corner perturbation"
    );
    Ok(())
}

/// A single distinct solution must not be reported as two.
///
/// If the alternate is a duplicate of the best, the ratio comes out at 1 and the
/// marker reads as maximally ambiguous — the exact inverse of the truth, and a
/// failure that would silently gate out perfectly good detections.
#[test]
fn a_lone_solution_is_not_reported_as_maximally_ambiguous() -> Result<()> {
    // A strongly oblique, off-centre view: the twin solution is far enough away
    // that refinement should not land on it.
    let pixels = project(&marker_at(1.4, 0.5, 3.0, 1.0));
    let solved = solve(&pixels)?;

    let ratio = solved.ambiguity_ratio();
    assert!(
        ratio < 1.0,
        "ratio came back at exactly {ratio}, which is what a duplicated solution produces"
    );
    Ok(())
}

/// The corner ordering is a contract, not an implementation detail.
///
/// Rotating the input corners by one position must rotate the recovered pose by
/// 90 degrees about the marker normal. If it does not, the ordering assumed here
/// disagrees with the one the detector produces, and every pose downstream is
/// quietly turned — a failure that presents as a calibration error.
#[test]
fn corner_order_is_pinned_to_the_marker_frame() -> Result<()> {
    let truth = marker_at(0.3, -0.2, 4.0, 0.6);
    let pixels = project(&truth);
    let rotated = [pixels[1], pixels[2], pixels[3], pixels[0]];

    let a = solve(&pixels)?.pose_1;
    let b = solve(&rotated)?.pose_1;

    let between = a.rotation.angle_to(&b.rotation).to_degrees();
    assert!(
        (between - 90.0).abs() < 1.0,
        "rotating the corner list turned the pose by {between:.2} deg, expected 90. \
         The corner order here does not match the detector's."
    );
    Ok(())
}
