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

//! ArUco detector node: images and `CameraInfo` in, `ArucoDetectionArray` out.
//!
//! Publishes the corners and both candidate poses per marker, plus the `k` the
//! corners were rectified with, so a recording replays without the camera.

use anyhow::{bail, Context as _, Result};
use arc_swap::ArcSwap;
use golfcart_aruco_detector::{
    dictionary::ArucoDictionary, BoardGeometry, Detector, DetectorParams, MarkerDetection,
};
use nalgebra::Isometry3;
use opencv::{core::Mat, prelude::*};
use rclrs::{
    log_error, log_info, log_warn, Context, CreateBasicExecutor, Node, Publisher, QoSProfile,
    RclrsErrorFilter, SpinOptions, SubscriptionOptions,
};
use std::{
    str::FromStr as _,
    sync::{
        atomic::{AtomicU32, Ordering},
        Arc,
    },
};

use aruco_detection_msgs::msg::{ArucoDetection, ArucoDetectionArray};
use geometry_msgs::msg::{Point, Pose, Quaternion};
use sensor_msgs::msg::{CameraInfo, CompressedImage, Image};
use std_msgs::msg::Header;

const NODE_NAME: &str = "golfcart_aruco_detector";

// ── configuration ───────────────────────────────────────────────────────────

struct Config {
    geometry: BoardGeometry,
    detector: DetectorParams,
    debug_overlay: bool,
    compressed: bool,
}

impl Config {
    fn from_node(node: &Node) -> Result<Self> {
        let dictionary = node
            .declare_parameter::<Arc<str>>("dictionary")
            .default("DICT_5X5_1000".into())
            .mandatory()?
            .get();

        let geometry = BoardGeometry {
            dictionary: ArucoDictionary::from_str(&dictionary)?,
            // Side of the BLACK SQUARE, not of the printed board: the board
            // carries a white quiet zone that is not part of the marker.
            // Getting this wrong scales every range linearly and presents as a
            // calibration error rather than a typo.
            marker_size_m: node
                .declare_parameter("marker_size")
                .default(0.384)
                .mandatory()?
                .get(),
            border_bits: node
                .declare_parameter("border_bits")
                .default(1_i64)
                .mandatory()?
                .get() as i32,
        };

        let mut detector = DetectorParams::default();

        let refinement = node
            .declare_parameter::<Arc<str>>("corner_refinement")
            .default("subpix".into())
            .mandatory()?
            .get();
        detector.corner_refinement.method = match refinement.as_ref() {
            "subpix" => golfcart_aruco_detector::CornerRefinement::Subpix,
            "contour" => golfcart_aruco_detector::CornerRefinement::Contour,
            // Selectable only so the contract test can prove refinement is
            // actually running. Never a sensible operational choice: it
            // quantises corners to the pixel grid, and corner error is the
            // direct input noise of the pose solve.
            "none" => golfcart_aruco_detector::CornerRefinement::None,
            other => bail!(
                "corner_refinement must be \"subpix\", \"contour\" or \"none\", got {other:?}"
            ),
        };
        detector.corner_refinement.win_size = node
            .declare_parameter("corner_refinement_win_size")
            .default(5_i64)
            .mandatory()?
            .get() as i32;
        detector.corner_refinement.max_iterations = node
            .declare_parameter("corner_refinement_max_iterations")
            .default(30_i64)
            .mandatory()?
            .get() as i32;
        detector.corner_refinement.min_accuracy = node
            .declare_parameter("corner_refinement_min_accuracy")
            .default(0.01)
            .mandatory()?
            .get();

        detector.adaptive_thresh.win_size_min = node
            .declare_parameter("adaptive_thresh_win_size_min")
            .default(13_i64)
            .mandatory()?
            .get() as i32;
        detector.adaptive_thresh.win_size_max = node
            .declare_parameter("adaptive_thresh_win_size_max")
            .default(33_i64)
            .mandatory()?
            .get() as i32;
        detector.adaptive_thresh.win_size_step = node
            .declare_parameter("adaptive_thresh_win_size_step")
            .default(10_i64)
            .mandatory()?
            .get() as i32;

        detector.candidate_filter.min_marker_perimeter_rate = node
            .declare_parameter("min_marker_perimeter_rate")
            .default(0.01)
            .mandatory()?
            .get();
        detector.candidate_filter.max_marker_perimeter_rate = node
            .declare_parameter("max_marker_perimeter_rate")
            .default(4.0)
            .mandatory()?
            .get();
        detector.candidate_filter.error_correction_rate = node
            .declare_parameter("error_correction_rate")
            .default(0.6)
            .mandatory()?
            .get();
        detector.candidate_filter.min_marker_distance_rate = node
            .declare_parameter("min_marker_distance_rate")
            .default(0.05)
            .mandatory()?
            .get();

        let debug_overlay = node
            .declare_parameter("debug_overlay")
            .default(false)
            .mandatory()?
            .get();

        // Defaults to compressed because that is what this vehicle actually
        // publishes: the gscam pipeline is configured with
        // `enable_pub_plugins: ["image_transport/compressed"]`, so no raw
        // sensor_msgs/Image exists on the camera topics at all. A node
        // subscribing to the raw topic here sits silent forever and looks like
        // a detector that cannot see anything.
        let compressed = node
            .declare_parameter("use_compressed")
            .default(true)
            .mandatory()?
            .get();

        Ok(Self {
            geometry,
            detector,
            debug_overlay,
            compressed,
        })
    }
}

// ── message construction ────────────────────────────────────────────────────

fn to_pose(pose: &Isometry3<f64>) -> Pose {
    let t = pose.translation.vector;
    let q = pose.rotation.quaternion();
    Pose {
        position: Point {
            x: t.x,
            y: t.y,
            z: t.z,
        },
        orientation: Quaternion {
            x: q.i,
            y: q.j,
            z: q.k,
            w: q.w,
        },
    }
}

fn to_message(detection: &MarkerDetection) -> ArucoDetection {
    let mut corners = [0.0f64; 8];
    for (i, corner) in detection.corners.iter().enumerate() {
        corners[i * 2] = corner.x as f64;
        corners[i * 2 + 1] = corner.y as f64;
    }

    ArucoDetection {
        id: detection.id,
        corners_rectified: corners,
        pose_1: to_pose(&detection.pose.pose_1),
        pose_2: to_pose(&detection.pose.pose_2),
        reprojection_error_1: detection.pose.error_1,
        // An infinite second error means only one distinct pose survived. It
        // travels as-is rather than being clamped: the consumer computes
        // err_1 / err_2 and an infinity there correctly yields 0, i.e.
        // maximally unambiguous. Substituting a large finite number would make
        // a lone solution look merely very good rather than unrivalled.
        reprojection_error_2: detection.pose.error_2,
    }
}

/// ROS `Image` to a grayscale OpenCV `Mat`.
///
/// Detection only ever reads intensity, so a colour frame is converted once
/// here rather than inside `detectMarkers` on every adaptive-threshold window.
fn image_to_mat(msg: &Image) -> Result<Mat> {
    use opencv::{
        core::{CV_8UC1, CV_8UC3},
        imgproc,
    };

    let (width, height) = (msg.width as i32, msg.height as i32);
    let rows_fit = |channels: u32| {
        msg.step as usize >= (msg.width * channels) as usize
            && msg.data.len() >= msg.step as usize * msg.height as usize
    };

    // SAFETY for both branches: `Mat::new_rows_cols_with_data` borrows the
    // message buffer without copying. The bounds check above guarantees the
    // buffer covers `step * height`, and the Mat is cloned or converted before
    // `msg` goes out of scope, so no Mat outlives the data it points at.
    let mat = match msg.encoding.as_str() {
        "mono8" => {
            if !rows_fit(1) {
                bail!(
                    "mono8 image data ({} bytes, step {}) is too short for {}x{}",
                    msg.data.len(),
                    msg.step,
                    msg.width,
                    msg.height
                );
            }
            unsafe {
                Mat::new_rows_cols_with_data(
                    height,
                    width,
                    CV_8UC1,
                    msg.data.as_ptr() as *mut std::ffi::c_void,
                    msg.step as usize,
                )?
                .try_clone()?
            }
        }
        encoding @ ("bgr8" | "rgb8") => {
            if !rows_fit(3) {
                bail!(
                    "{encoding} image data ({} bytes, step {}) is too short for {}x{}",
                    msg.data.len(),
                    msg.step,
                    msg.width,
                    msg.height
                );
            }
            let colour = unsafe {
                Mat::new_rows_cols_with_data(
                    height,
                    width,
                    CV_8UC3,
                    msg.data.as_ptr() as *mut std::ffi::c_void,
                    msg.step as usize,
                )?
            };
            let mut gray = Mat::default();
            let code = if encoding == "bgr8" {
                imgproc::COLOR_BGR2GRAY
            } else {
                imgproc::COLOR_RGB2GRAY
            };
            imgproc::cvt_color(&colour, &mut gray, code, 0)?;
            gray
        }
        other => bail!("unsupported image encoding {other:?}; handled: mono8, bgr8, rgb8"),
    };

    Ok(mat)
}

/// Decode a JPEG/PNG frame to grayscale.
///
/// Decoding straight to grayscale rather than colour-then-convert: detection
/// only reads intensity, and this skips both a colour decode and a conversion
/// pass per frame.
fn compressed_to_mat(msg: &CompressedImage) -> Result<Mat> {
    use opencv::imgcodecs;

    let buffer = Mat::from_slice(&msg.data)?;
    let mat = imgcodecs::imdecode(&buffer, imgcodecs::IMREAD_GRAYSCALE)?;
    if mat.empty() {
        bail!(
            "could not decode a {} byte {:?} frame",
            msg.data.len(),
            msg.format
        );
    }
    Ok(mat)
}

fn publish_overlay(
    detector: &Detector,
    raw: &Mat,
    original: &Image,
    publisher: &Publisher<Image>,
) -> Result<()> {
    let rectified = detector.rectify(raw)?;
    let step = rectified.cols() as u32;
    let data = rectified
        .data_bytes()
        .context("overlay image has no data")?
        .to_vec();

    publisher.publish(&Image {
        header: original.header.clone(),
        height: rectified.rows() as u32,
        width: rectified.cols() as u32,
        encoding: "mono8".to_string(),
        is_bigendian: 0,
        step,
        data,
    })?;
    Ok(())
}

// ── node ────────────────────────────────────────────────────────────────────

fn main() -> Result<()> {
    let mut executor = Context::default_from_env()?.create_basic_executor();
    let node = executor.create_node(NODE_NAME)?;

    let config = Config::from_node(&node)?;
    log_info!(
        NODE_NAME,
        "{} markers, {:.3} m side, {} border bits, refinement {:?}",
        config.geometry.dictionary,
        config.geometry.marker_size_m,
        config.geometry.border_bits,
        config.detector.corner_refinement.method
    );

    // The detector cannot be built until CameraInfo arrives, and is rebuilt if
    // the calibration changes. ArcSwap so the image callback reads it without
    // taking a lock on every frame.
    let detector_state: Arc<ArcSwap<Option<Arc<Detector>>>> = Arc::new(ArcSwap::from_pointee(None));

    let detections_publisher = node.create_publisher::<ArucoDetectionArray>("~/output/detections")?;
    let overlay_publisher = config
        .debug_overlay
        .then(|| node.create_publisher::<Image>("~/output/overlay"))
        .transpose()?;

    // Sensor data: best-effort, keep last. A dropped frame is preferable to a
    // queue of stale ones, because a detection is only useful near its stamp.
    let sensor_qos = QoSProfile::sensor_data_default().keep_last(1);
    let sub_opts = |topic: &'static str| {
        let mut opts = SubscriptionOptions::new(topic);
        opts.qos = sensor_qos;
        opts
    };

    let _info_subscription = {
        let state = Arc::clone(&detector_state);
        let geometry = config.geometry;
        let params = config.detector;
        node.create_subscription(sub_opts("~/input/camera_info"), move |msg: CameraInfo| {
            match Detector::new(geometry, params, &msg.k, &msg.d, &msg.distortion_model) {
                Ok(detector) => {
                    let first = state.load().is_none();
                    state.store(Arc::new(Some(Arc::new(detector))));
                    if first {
                        log_info!(
                            NODE_NAME,
                            "calibration received: {}x{}, {} distortion coefficients ({})",
                            msg.width,
                            msg.height,
                            msg.d.len(),
                            msg.distortion_model
                        );
                    }
                }
                Err(error) => {
                    // Throttled: a bad calibration republishes at the info
                    // topic's rate and would otherwise flood the log.
                    static COUNT: AtomicU32 = AtomicU32::new(0);
                    if COUNT.fetch_add(1, Ordering::Relaxed) % 30 == 0 {
                        log_error!(
                            NODE_NAME,
                            "unusable CameraInfo, detector not built: {error:#}"
                        );
                    }
                }
            }
        })?
    };

    // One code path for both transports. `mat` is already grayscale; `header`
    // is the sensor's own, because the localizer compensates for vehicle motion
    // using that stamp and substituting `now()` would build in a latency-shaped
    // position error that grows with speed.
    let handle_frame = {
        let detections_publisher = detections_publisher.clone();
        move |detector: &Detector, mat: &Mat, header: &Header, width: u32, height: u32| {
            let detections = match detector.detect(mat) {
                Ok(detections) => detections,
                Err(error) => {
                    log_error!(NODE_NAME, "detection failed: {error:#}");
                    return;
                }
            };

            // Published even when empty. "No markers in view" is information the
            // localizer needs to tell a coverage gap from a detector that has
            // stopped running.
            let message = ArucoDetectionArray {
                header: header.clone(),
                k: *detector.k(),
                image_width: width,
                image_height: height,
                detections: detections.iter().map(to_message).collect(),
            };

            if let Err(error) = detections_publisher.publish(&message) {
                log_error!(NODE_NAME, "publish failed: {error}");
            }
        }
    };

    /// Shared "waiting for calibration" complaint, throttled: without it this
    /// prints once per frame for as long as the camera stays uncalibrated.
    fn warn_no_calibration() {
        static COUNT: AtomicU32 = AtomicU32::new(0);
        if COUNT.fetch_add(1, Ordering::Relaxed) % 60 == 0 {
            log_warn!(
                NODE_NAME,
                "images arriving but no CameraInfo yet; nothing can be detected \
                 until the camera publishes its calibration"
            );
        }
    }

    // Only one of these is created. Which one matters: see `use_compressed`.
    let mut _raw_subscription = None;
    let mut _compressed_subscription = None;

    if config.compressed {
        let state = Arc::clone(&detector_state);
        let overlay_publisher = overlay_publisher.clone();
        let handle_frame = handle_frame.clone();
        _compressed_subscription = Some(node.create_subscription(
            sub_opts("~/input/image/compressed"),
            move |msg: CompressedImage| {
                let loaded = state.load();
                let Some(detector) = loaded.as_ref().as_ref() else {
                    warn_no_calibration();
                    return;
                };
                let mat = match compressed_to_mat(&msg) {
                    Ok(mat) => mat,
                    Err(error) => {
                        log_error!(NODE_NAME, "cannot decode image: {error:#}");
                        return;
                    }
                };
                let (width, height) = (mat.cols() as u32, mat.rows() as u32);
                handle_frame(detector, &mat, &msg.header, width, height);

                if let Some(publisher) = &overlay_publisher {
                    let original = Image {
                        header: msg.header.clone(),
                        ..Default::default()
                    };
                    if let Err(error) = publish_overlay(detector, &mat, &original, publisher) {
                        log_warn!(NODE_NAME, "overlay failed: {error:#}");
                    }
                }
            },
        )?);
    } else {
        let state = Arc::clone(&detector_state);
        let overlay_publisher = overlay_publisher.clone();
        _raw_subscription = Some(node.create_subscription(
            sub_opts("~/input/image"),
            move |msg: Image| {
                let loaded = state.load();
                let Some(detector) = loaded.as_ref().as_ref() else {
                    warn_no_calibration();
                    return;
                };
                let mat = match image_to_mat(&msg) {
                    Ok(mat) => mat,
                    Err(error) => {
                        log_error!(NODE_NAME, "cannot read image: {error:#}");
                        return;
                    }
                };
                handle_frame(detector, &mat, &msg.header, msg.width, msg.height);

                if let Some(publisher) = &overlay_publisher {
                    if let Err(error) = publish_overlay(detector, &mat, &msg, publisher) {
                        log_warn!(NODE_NAME, "overlay failed: {error:#}");
                    }
                }
            },
        )?);
    }

    log_info!(
        NODE_NAME,
        "subscribed to the {} image topic",
        if config.compressed { "compressed" } else { "raw" }
    );

    log_info!(NODE_NAME, "detector running");
    executor.spin(SpinOptions::default()).first_error()?;
    Ok(())
}
