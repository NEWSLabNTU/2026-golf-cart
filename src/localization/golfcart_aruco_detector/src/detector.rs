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

//! Images in, rectified corners and candidate poses out.
//!
//! Vendored from LCTK's `aruco-detector`, trimmed to what localization needs.
//! Dropped in the merge: the ICP board fit, the all-or-nothing board detection
//! mode, `estimate_pose()`, and the MRPT calibration file loader. This system
//! uses single-ID boards and takes intrinsics from `CameraInfo`, so none of that
//! has a caller here. LCTK keeps them for calibration.

use crate::{
    dictionary::ArucoDictionary,
    marker_pnp::{solve_marker_pose, MarkerPose},
    params::DetectorParams,
};
use anyhow::{bail, ensure, Result};
use nalgebra::Point2;
use opencv::{
    aruco, calib3d,
    core::{self as core_cv, Mat, Point2f, TermCriteria, TermCriteria_Type, Vector},
    prelude::*,
    types::VectorOfMat,
};

pub const NUM_CORNERS: usize = 4;

/// One detected marker: where its corners are, and where it might be.
#[derive(Clone, Debug)]
pub struct MarkerDetection {
    pub id: u32,
    /// Corners in the RECTIFIED frame, in OpenCV's detection order:
    /// top-left, top-right, bottom-right, bottom-left.
    pub corners: [Point2<f32>; NUM_CORNERS],
    pub pose: MarkerPose,
}

/// The printed marker. Single-ID boards, so there is no grid to describe.
///
/// LCTK's `MultiArucoPattern` derived the marker size from board size, border
/// and a square ratio because it prints the board. Here the boards are already
/// printed and measured, so the size is stated directly — one number that can be
/// checked against a tape measure, rather than three that have to agree.
#[derive(Clone, Copy, Debug)]
pub struct BoardGeometry {
    pub dictionary: ArucoDictionary,
    /// Side length of the black marker square, in metres. NOT the board size:
    /// the printed board has a white quiet zone around the marker which is not
    /// part of it.
    pub marker_size_m: f64,
    pub border_bits: i32,
}

/// Check that a declared distortion model and its coefficient count agree.
///
/// OpenCV decides which distortion function to apply purely from the length of
/// `D`: 4 or 5 is plumb-bob, 8/12/14 pulls in the rational, thin-prism and
/// tilted-sensor terms. It never looks at the model name, so a mismatch between
/// the two is silent, and shows up as poses wrong by an amount that grows toward
/// the image edge — exactly where the wide-field observations live.
pub fn validate_distortion(model: &str, count: usize) -> Result<()> {
    // An empty D is the pinhole case and is always consistent.
    if count == 0 {
        return Ok(());
    }
    match model {
        "plumb_bob" | "rational_polynomial" | "" => {}
        other => bail!(
            "unsupported distortion_model {other:?}; this detector handles \
             plumb_bob and rational_polynomial"
        ),
    }
    ensure!(
        matches!(count, 4 | 5 | 8 | 12 | 14),
        "distortion_model {model:?} came with {count} coefficients; OpenCV accepts \
         4, 5, 8, 12 or 14 and picks the model from that count alone"
    );
    if model == "plumb_bob" {
        ensure!(
            count <= 5,
            "distortion_model is plumb_bob but {count} coefficients were supplied. \
             This is almost always a rational_polynomial calibration that has been \
             mislabelled; keeping only the first five would drop the k4-k6 denominator."
        );
    }
    if model == "rational_polynomial" {
        ensure!(
            count >= 8,
            "distortion_model is rational_polynomial but only {count} coefficients \
             were supplied; the rational form needs at least 8"
        );
    }
    Ok(())
}

pub struct Detector {
    geometry: BoardGeometry,
    params: DetectorParams,
    /// The intrinsics as received, kept so the detections can carry the exact
    /// `k` their corners were rectified with. A consumer that re-derived this
    /// from a live CameraInfo would silently use the wrong one after a
    /// recalibration, and worse on a replayed recording.
    k: [f64; 9],
    camera_matrix: Mat,
    distortion: Mat,
    /// Built once. `get_predefined_dictionary` is not free, and this used to be
    /// rebuilt per frame.
    dictionary: core_cv::Ptr<aruco::Dictionary>,
    opencv_params: core_cv::Ptr<aruco::DetectorParameters>,
}

// Mat is not Sync, but this is only ever read after construction.
unsafe impl Sync for Detector {}
unsafe impl Send for Detector {}

impl Detector {
    /// `k` is the row-major 3x3 intrinsic matrix, `d` the distortion
    /// coefficients, both as they arrive on `CameraInfo`.
    pub fn new(
        geometry: BoardGeometry,
        params: DetectorParams,
        k: &[f64; 9],
        d: &[f64],
        distortion_model: &str,
    ) -> Result<Self> {
        ensure!(
            geometry.marker_size_m > 0.0,
            "marker_size_m must be positive, got {}",
            geometry.marker_size_m
        );
        ensure!(
            k[0] > 0.0 && k[4] > 0.0,
            "camera matrix has a non-positive focal length ({}, {}); \
             CameraInfo has probably not been populated",
            k[0],
            k[4]
        );
        validate_distortion(distortion_model, d.len())?;

        // Validated once here rather than per frame.
        let opencv_params = params.to_opencv(geometry.border_bits)?;

        Ok(Self {
            geometry,
            params,
            k: *k,
            camera_matrix: Mat::from_slice(k)?.reshape(1, 3)?.try_clone()?,
            distortion: Mat::from_slice(d)?.try_clone()?,
            dictionary: geometry.dictionary.to_opencv()?,
            opencv_params,
        })
    }

    pub fn geometry(&self) -> BoardGeometry {
        self.geometry
    }

    pub fn params(&self) -> DetectorParams {
        self.params
    }

    pub fn camera_matrix(&self) -> &Mat {
        &self.camera_matrix
    }

    /// The intrinsics the corners were rectified with, as the flat row-major
    /// array `CameraInfo` and `ArucoDetectionArray` both use.
    pub fn k(&self) -> &[f64; 9] {
        &self.k
    }

    /// Rectify a raw image.
    ///
    /// **Visualization only.** It is not part of the detection path: `undistort`
    /// resamples the image bilinearly and that blunts exactly the gradients
    /// sub-pixel corner refinement depends on. Use it to draw a debug overlay in
    /// the same frame the corners are reported in.
    pub fn rectify(&self, image: &Mat) -> Result<Mat> {
        let mut rectified = Mat::default();
        calib3d::undistort(
            image,
            &mut rectified,
            &self.camera_matrix,
            &self.distortion,
            &core_cv::no_array(),
        )?;
        Ok(rectified)
    }

    /// Map corners from the raw (distorted) frame into the rectified frame.
    ///
    /// `P = K` is what makes the output pixel coordinates; omitting it yields
    /// *normalized* coordinates instead, which is the easy way to get this
    /// silently and subtly wrong. The iterative form is used because OpenCV's
    /// default five iterations leave real residual error under strong
    /// distortion.
    fn undistort_corners(&self, corners: &VectorOfMat) -> Result<VectorOfMat> {
        let eye = Mat::eye(3, 3, core_cv::CV_64FC1)?.to_mat()?;
        let criteria = TermCriteria::new(
            TermCriteria_Type::COUNT as i32 + TermCriteria_Type::EPS as i32,
            20,
            1e-8,
        )?;

        corners
            .iter()
            .map(|marker_corners| -> Result<Mat> {
                let mut undistorted = Mat::default();
                calib3d::undistort_points_iter(
                    &marker_corners,
                    &mut undistorted,
                    &self.camera_matrix,
                    &self.distortion,
                    &eye,
                    &self.camera_matrix,
                    criteria,
                )?;
                Ok(undistorted)
            })
            .collect()
    }

    /// Detect every marker of the configured dictionary in a **raw (distorted)**
    /// image, and solve each one's pose.
    ///
    /// The four-step sequence below is load-bearing and must not be rearranged:
    ///
    /// 1. detect on the RAW frame
    /// 2. sub-pixel refine on the RAW frame
    /// 3. map corners to the rectified frame with `undistortPoints(R = I, P = K)`
    /// 4. PnP with ZERO distortion — the corners are already rectified
    ///
    /// Steps 1-2 run raw because undistorting the image resamples it and blunts
    /// the gradients refinement reads. Step 4 must pass zero distortion:
    /// passing `D` again double-corrects, which LCTK measured at 40 px of
    /// displacement on a ~900 px image.
    ///
    /// Do NOT hand this a rectified image; that corrects it twice.
    pub fn detect(&self, image: &Mat) -> Result<Vec<MarkerDetection>> {
        ensure!(!image.empty(), "input image is empty");

        let mut corners_raw = VectorOfMat::new();
        let mut ids = Vector::<i32>::new();

        #[allow(clippy::unnecessary_mut_passed)]
        aruco::detect_markers(
            image,
            &self.dictionary,
            &mut corners_raw,
            &mut ids,
            &self.opencv_params,
            &mut core_cv::no_array(),
            &mut core_cv::no_array(),
            &mut core_cv::no_array(),
        )?;

        if ids.is_empty() {
            return Ok(Vec::new());
        }

        let corners_rectified = self.undistort_corners(&corners_raw)?;

        let mut out = Vec::with_capacity(ids.len());
        for (index, id) in ids.iter().enumerate() {
            let Ok(corners_mat) = corners_rectified.get(index) else {
                continue;
            };
            let corners = match extract_corners(&corners_mat) {
                Ok(corners) => corners,
                Err(error) => {
                    log::warn!("marker {id}: unreadable corners: {error}");
                    continue;
                }
            };

            // A marker with no usable pose is dropped rather than reported with
            // a placeholder: downstream gates on the ambiguity metric, and a
            // fabricated pose carries a fabricated confidence with it.
            match solve_marker_pose(&corners, self.geometry.marker_size_m, &self.camera_matrix) {
                Ok(pose) => out.push(MarkerDetection {
                    id: id as u32,
                    corners,
                    pose,
                }),
                Err(error) => log::warn!("marker {id} has no usable pose: {error}"),
            }
        }

        Ok(out)
    }
}

/// Pull the four corners out of OpenCV's per-marker Mat, which may be 1x4 or
/// 4x1 depending on how it was built.
fn extract_corners(mat: &Mat) -> Result<[Point2<f32>; NUM_CORNERS]> {
    let mut corners = [Point2::new(0.0f32, 0.0f32); NUM_CORNERS];
    for (i, slot) in corners.iter_mut().enumerate() {
        let point: &Point2f = match mat.at_2d(0, i as i32) {
            Ok(point) => point,
            Err(_) => mat.at_2d(i as i32, 0)?,
        };
        *slot = Point2::new(point.x, point.y);
    }
    Ok(corners)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mislabelled_plumb_bob_is_rejected() {
        assert!(validate_distortion("plumb_bob", 12).is_err());
        assert!(validate_distortion("plumb_bob", 5).is_ok());
    }

    #[test]
    fn rational_polynomial_needs_its_denominator() {
        assert!(validate_distortion("rational_polynomial", 5).is_err());
        assert!(validate_distortion("rational_polynomial", 8).is_ok());
        assert!(validate_distortion("rational_polynomial", 12).is_ok());
    }

    #[test]
    fn a_count_opencv_cannot_interpret_is_rejected() {
        assert!(validate_distortion("rational_polynomial", 9).is_err());
    }

    #[test]
    fn an_empty_d_is_the_pinhole_case() {
        assert!(validate_distortion("plumb_bob", 0).is_ok());
    }

    #[test]
    fn an_unpopulated_camera_info_is_rejected_at_construction() {
        // All-zero K is what CameraInfo looks like before calibration arrives.
        let result = Detector::new(
            BoardGeometry {
                dictionary: ArucoDictionary::DICT_5X5_1000,
                marker_size_m: 0.384,
                border_bits: 1,
            },
            DetectorParams::default(),
            &[0.0; 9],
            &[0.0; 5],
            "plumb_bob",
        );
        assert!(result.is_err(), "an all-zero camera matrix was accepted");
    }
}
