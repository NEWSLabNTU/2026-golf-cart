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

//! Per-marker pose recovery with an ambiguity metric.
//!
//! A square marker seen by one camera generally has **two** poses that reproject
//! onto the same four corners. Which one is correct cannot be decided from that
//! marker alone; what can be decided is how *distinguishable* they are, and that
//! is what the ambiguity ratio reports. Callers gate on it, or resolve the
//! ambiguity by agreement across several markers.
//!
//! Vendored from LCTK, where this replaced a path that called
//! `estimatePoseSingleMarkers` — discarding the second solution entirely and
//! reporting a hardcoded confidence — and passed non-zero distortion
//! coefficients against corners that had already been rectified.

use anyhow::{ensure, Result};
use nalgebra::{Isometry3, Point2, Point3, Translation3, UnitQuaternion};
use opencv::{
    calib3d,
    core::{self as core_cv, Mat, Point2f, Point3f, TermCriteria, TermCriteria_Type, Vector},
    prelude::*,
};

/// Two candidate poses for one marker, best first.
///
/// `error_1 <= error_2`, both in pixels and both computed here rather than taken
/// from OpenCV — see [`solve_marker_pose`] for why that distinction matters.
///
/// `error_1 / error_2` is the ambiguity metric, in `(0, 1]`. Near 0 the better
/// solution fits far better and the pose is trustworthy; near 1 the two fit
/// equally well and this marker cannot resolve its own orientation.
///
/// Note the direction: the ratio is best-over-worst, so it *rises* toward 1 as
/// the marker becomes less certain. An earlier revision of the spec had this
/// inverted, which made the gate unable to fire at all.
///
/// Measured in phase 3D-5, and worth reading before gating on it: this ratio
/// does NOT flag near-fronto-parallel views. Below about 10 degrees of tilt it
/// reports 0 — maximum confidence — precisely where orientation is least
/// reliable, because the twin solution is not yet distinct enough to act as a
/// rival. It is a resolution gate, not a geometry gate; the localizer's
/// `min_view_angle_deg` is what excludes those views.
#[derive(Clone, Copy, Debug)]
pub struct MarkerPose {
    pub pose_1: Isometry3<f64>,
    pub pose_2: Isometry3<f64>,
    pub error_1: f64,
    pub error_2: f64,
}

impl MarkerPose {
    /// Best-over-worst reprojection error, in `(0, 1]`.
    ///
    /// Infinite `error_2` — only one distinct pose survived — gives 0, which is
    /// correct: a marker with no viable alternate is maximally unambiguous.
    pub fn ambiguity_ratio(&self) -> f64 {
        if self.error_2 > 0.0 {
            self.error_1 / self.error_2
        } else {
            1.0
        }
    }
}

/// The four corners of a marker in its own frame, in OpenCV's detection order:
/// top-left, top-right, bottom-right, bottom-left, with +z out of the face.
///
/// This ordering is a contract between the detector, the PnP here, and anything
/// consuming the corners downstream. Rotating it by one position rotates every
/// recovered pose by 90 degrees about the marker normal, which is a failure that
/// looks like a calibration error rather than an indexing one.
pub fn marker_local_corners(marker_size_m: f64) -> [Point3<f64>; 4] {
    let h = marker_size_m / 2.0;
    [
        Point3::new(-h, h, 0.0),
        Point3::new(h, h, 0.0),
        Point3::new(h, -h, 0.0),
        Point3::new(-h, -h, 0.0),
    ]
}

/// OpenCV's (rvec, tvec) to an `Isometry3`.
///
/// Written out rather than pulled from `cv-convert`, whose feature flags pin an
/// exact OpenCV minor version and do not cover the one this package builds
/// against. Fifteen lines is cheaper than a dependency that breaks on an
/// OpenCV bump.
pub fn to_isometry(rvec: &Mat, tvec: &Mat) -> Result<Isometry3<f64>> {
    let mut rotation = Mat::default();
    calib3d::rodrigues(rvec, &mut rotation, &mut core_cv::no_array())?;

    let mut m = nalgebra::Matrix3::<f64>::zeros();
    for row in 0..3 {
        for col in 0..3 {
            m[(row, col)] = *rotation.at_2d::<f64>(row as i32, col as i32)?;
        }
    }

    // Rodrigues always returns a proper rotation, so this normalization is a
    // guard against accumulated float error, not a fix for a non-rotation.
    let rotation = UnitQuaternion::from_matrix(&m);
    let translation = Translation3::new(
        *tvec.at::<f64>(0)?,
        *tvec.at::<f64>(1)?,
        *tvec.at::<f64>(2)?,
    );

    Ok(Isometry3::from_parts(translation, rotation))
}

/// Worst-corner reprojection error in pixels, computed from the pose directly.
///
/// Deliberately the worst corner rather than the mean: a pose that fits three
/// corners and misses the fourth is wrong, and averaging hides exactly that.
fn reprojection_error(
    pose: &Isometry3<f64>,
    object: &[Point3<f64>; 4],
    pixels: &[Point2<f32>; 4],
    fx: f64,
    fy: f64,
    cx: f64,
    cy: f64,
) -> f64 {
    let mut worst: f64 = 0.0;
    for (obj, px) in object.iter().zip(pixels) {
        let c = pose * obj;
        if c.z <= 1e-9 {
            // Behind the camera. Not a large error, an invalid one.
            return f64::MAX;
        }
        let u = fx * c.x / c.z + cx;
        let v = fy * c.y / c.z + cy;
        worst = worst.max(((u - px.x as f64).powi(2) + (v - px.y as f64).powi(2)).sqrt());
    }
    worst
}

/// Recover both poses of a square marker from its four **rectified** corners.
///
/// `camera_matrix` is the 3x3 `K`. Distortion is zero here by construction: the
/// corners have already been mapped into the rectified frame by
/// `Detector::undistort_corners`, and passing `D` again would correct them twice
/// — measured by LCTK at 40 px of displacement on a ~900 px image.
///
/// # Why this is not just `solvePnPGeneric(SOLVEPNP_IPPE_SQUARE)`
///
/// On OpenCV 4.5.4 — the version this project builds against — that call returns
/// poses that do not reproject. Measured on noiseless synthetic corners, where
/// the correct answer reprojects to zero by construction, the *better* of its
/// two solutions was off by:
///
/// | geometry | best-solution error |
/// |---|---|
/// | fronto-parallel, centred | 115 px |
/// | 0.2 rad tilt, off-centre | 0.016 px |
/// | 0.5 rad tilt, off-centre | 2.84 px |
/// | 0.9 rad tilt, off-centre | 0.008 px |
///
/// `estimatePoseSingleMarkers` looks correct only because on 4.5.4 it quietly
/// calls `solvePnP` with the default `SOLVEPNP_ITERATIVE` — it does not use IPPE
/// at all. IPPE_SQUARE became the default in the 4.7 `ArucoDetector` API, not
/// here.
///
/// So: seed from **both** `SOLVEPNP_ITERATIVE` and `SOLVEPNP_IPPE_SQUARE`,
/// polish every candidate with `solvePnPRefineLM`, and score them with a
/// reprojection error computed in this function rather than the one OpenCV
/// hands back. After refinement every geometry tested recovers the true pose to
/// about 1e-5 px, and the ambiguity ratio becomes meaningful.
///
/// Skipping the refinement yields a detector that looks like it works, reports
/// small residuals, and is quietly wrong.
pub fn solve_marker_pose(
    pixels: &[Point2<f32>; 4],
    marker_size_m: f64,
    camera_matrix: &Mat,
) -> Result<MarkerPose> {
    ensure!(
        camera_matrix.rows() == 3 && camera_matrix.cols() == 3,
        "camera matrix must be 3x3, got {}x{}",
        camera_matrix.rows(),
        camera_matrix.cols()
    );

    let fx = *camera_matrix.at_2d::<f64>(0, 0)?;
    let fy = *camera_matrix.at_2d::<f64>(1, 1)?;
    let cx = *camera_matrix.at_2d::<f64>(0, 2)?;
    let cy = *camera_matrix.at_2d::<f64>(1, 2)?;

    let object = marker_local_corners(marker_size_m);
    let object_cv: Vector<Point3f> = object
        .iter()
        .map(|p| Point3f::new(p.x as f32, p.y as f32, p.z as f32))
        .collect();
    let pixels_cv: Vector<Point2f> = pixels.iter().map(|p| Point2f::new(p.x, p.y)).collect();

    // Already rectified — see the note above.
    let distortion = Mat::zeros(5, 1, core_cv::CV_64FC1)?.to_mat()?;

    let mut candidates: Vec<(Mat, Mat)> = Vec::new();

    {
        let mut rvec = Mat::default();
        let mut tvec = Mat::default();
        let ok = calib3d::solve_pnp(
            &object_cv,
            &pixels_cv,
            camera_matrix,
            &distortion,
            &mut rvec,
            &mut tvec,
            false,
            calib3d::SOLVEPNP_ITERATIVE,
        )?;
        if ok {
            candidates.push((rvec, tvec));
        }
    }

    {
        let mut rvecs = Vector::<Mat>::new();
        let mut tvecs = Vector::<Mat>::new();
        let mut errors = Mat::default();
        calib3d::solve_pnp_generic(
            &object_cv,
            &pixels_cv,
            camera_matrix,
            &distortion,
            &mut rvecs,
            &mut tvecs,
            false,
            calib3d::SolvePnPMethod::SOLVEPNP_IPPE_SQUARE,
            &core_cv::no_array(),
            &core_cv::no_array(),
            &mut errors,
        )?;
        for (rvec, tvec) in rvecs.iter().zip(tvecs.iter()) {
            candidates.push((rvec, tvec));
        }
    }

    ensure!(
        !candidates.is_empty(),
        "no PnP solution for the given corners"
    );

    // Polish every seed, then score them ourselves.
    let criteria = TermCriteria::new(
        TermCriteria_Type::COUNT as i32 + TermCriteria_Type::EPS as i32,
        20,
        f64::EPSILON,
    )?;

    let mut scored: Vec<(f64, Isometry3<f64>)> = Vec::with_capacity(candidates.len());
    for (rvec, tvec) in &candidates {
        let mut rvec = if rvec.typ() == core_cv::CV_64FC1 {
            rvec.clone()
        } else {
            let mut converted = Mat::default();
            rvec.convert_to(&mut converted, core_cv::CV_64FC1, 1.0, 0.0)?;
            converted
        };
        let mut tvec = if tvec.typ() == core_cv::CV_64FC1 {
            tvec.clone()
        } else {
            let mut converted = Mat::default();
            tvec.convert_to(&mut converted, core_cv::CV_64FC1, 1.0, 0.0)?;
            converted
        };

        calib3d::solve_pnp_refine_lm(
            &object_cv,
            &pixels_cv,
            camera_matrix,
            &distortion,
            &mut rvec,
            &mut tvec,
            criteria,
        )?;

        let pose = to_isometry(&rvec, &tvec)?;
        let error = reprojection_error(&pose, &object, pixels, fx, fy, cx, cy);
        scored.push((error, pose));
    }
    scored.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));

    // Distinct solutions only. Refining several seeds often lands them on the
    // same answer, and reporting a duplicate as the "alternate" would make every
    // marker look unambiguous — the exact opposite of the truth, and worse than
    // reporting no metric at all.
    let mut distinct: Vec<(f64, Isometry3<f64>)> = Vec::with_capacity(2);
    for candidate in scored {
        let duplicate = distinct.iter().any(|(_, kept)| {
            let translation = (kept.translation.vector - candidate.1.translation.vector).norm();
            let rotation = kept.rotation.angle_to(&candidate.1.rotation);
            translation < 1e-4 && rotation < 1e-3
        });
        if !duplicate {
            distinct.push(candidate);
        }
        if distinct.len() == 2 {
            break;
        }
    }

    let (error_1, pose_1) = distinct[0];
    let (error_2, pose_2) = if distinct.len() > 1 {
        distinct[1]
    } else {
        // Only one distinct pose survived. Reporting it twice would give a ratio
        // of 1 and read as maximally ambiguous, which inverts the meaning.
        (f64::INFINITY, pose_1)
    };

    Ok(MarkerPose {
        pose_1,
        pose_2,
        error_1,
        error_2,
    })
}
