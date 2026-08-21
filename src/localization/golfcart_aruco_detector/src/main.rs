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

use anyhow::{anyhow, bail, Context as _, Result};
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
use rclrs_image_transport::{subscribe_image, DecodedImage, Frame, Scale, Target, Transport};
use sensor_msgs::msg::{CameraInfo, Image};
use std_msgs::msg::Header;

const NODE_NAME: &str = "golfcart_aruco_detector";

// ── configuration ───────────────────────────────────────────────────────────

struct Config {
    geometry: BoardGeometry,
    detector: DetectorParams,
    debug_overlay: bool,
    transport: Transport,
    decode_scale: Scale,
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

        // Coarse detect on a reduced frame, corners refined at full resolution.
        // Detection cost is per-pixel, so this is the only knob that moves it
        // much: 38.1 ms to 11.8 ms at 2, measured on an AGX Orin at 1920x1280.
        // What it trades is the smallest marker that can still be FOUND, not
        // corner precision -- the refinement runs against the full frame.
        detector.detection_downscale = node
            .declare_parameter("detection_downscale")
            .default(1_i64)
            .mandatory()?
            .get() as i32;

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

        // The transport hint, spelled the way image_transport spells it, so a
        // node moves between raw and compressed by configuration rather than by
        // a code change.
        //
        // Defaults to compressed because that is what this vehicle actually
        // publishes: the gscam pipeline runs `image_encoding: "jpeg"`, so no
        // raw sensor_msgs/Image exists on the camera topics at all. A node
        // subscribing to the raw topic here sits silent forever and looks like
        // a detector that cannot see anything.
        // Decode the JPEG at a fraction of its stored size. libjpeg does this
        // inside the IDCT, so it is cheaper than decoding and resizing, and it
        // is a DIFFERENT knob from detection_downscale: this one throws pixels
        // away before anything sees them, so corner precision really is
        // reduced. detection_downscale keeps the full frame for the refinement
        // and only searches a reduced one.
        //
        // Reach for detection_downscale first. This is here for the case where
        // the decode itself is the cost, or where the wire format is larger
        // than the detector needs.
        let decode_scale = node
            .declare_parameter("image_decode_scale")
            .default(1_i64)
            .mandatory()?
            .get();
        let decode_scale = u32::try_from(decode_scale)
            .ok()
            .and_then(Scale::from_divisor)
            .ok_or_else(|| {
                anyhow!(
                    "image_decode_scale must be 1, 2, 4 or 8 (the fractions libjpeg \
                     can produce during the IDCT), got {decode_scale}"
                )
            })?;

        let hint = node
            .declare_parameter::<Arc<str>>("image_transport")
            .default("compressed".into())
            .mandatory()?
            .get();
        let transport = Transport::from_hint(&hint).map_err(|error| anyhow!("{error}"))?;

        // The scaled decode happens inside libjpeg, so it exists only on the
        // compressed transport; the raw path hands the image over untouched.
        // Accepting the combination would scale the intrinsics for a reduction
        // that never happened, and every pose would come out wrong by the
        // factor with nothing to indicate it. Refused rather than ignored: a
        // parameter silently doing nothing is how the wrong one gets left set.
        if transport == Transport::Raw && decode_scale != Scale::Full {
            bail!(
                "image_decode_scale is {:?}, but it only applies to the compressed \
                 transport -- the raw transport delivers whatever the publisher sent. \
                 Set image_transport to \"compressed\", or image_decode_scale to 1",
                decode_scale
            );
        }

        Ok(Self {
            geometry,
            detector,
            debug_overlay,
            transport,
            decode_scale,
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

/// Borrow a decoded grayscale buffer as an OpenCV `Mat`.
///
/// Decoding happens in `rclrs_image_transport` now, on both transports: JPEG
/// straight to one channel for the compressed topic, a luma conversion for a
/// raw colour one. What used to be two functions here -- one calling `imdecode`
/// and one juggling `cvt_color` per encoding -- is that crate's job, and the
/// `CompressedImage.format` contract came with it. See
/// docs/roadmaps/2-camera-image-pipeline.md.
///
/// No copy: the `Mat` points into the decoded buffer. The caller keeps the
/// frame alive for as long as it uses the `Mat`, which is the same discipline
/// the previous version needed.
fn as_gray_mat(image: &DecodedImage) -> Result<Mat> {
    use opencv::core::CV_8UC1;

    if image.channels != 1 {
        bail!(
            "expected a single-channel image, got {} channels",
            image.channels
        );
    }
    let want = image.step * image.height;
    if image.data.len() < want {
        bail!(
            "decoded buffer is {} bytes, {want} needed for {}x{}",
            image.data.len(),
            image.width,
            image.height
        );
    }

    // SAFETY: `new_rows_cols_with_data` borrows rather than copies. The bounds
    // check above guarantees the buffer covers `step * height`, and the Mat
    // does not outlive `image`.
    let mat = unsafe {
        Mat::new_rows_cols_with_data(
            image.height as i32,
            image.width as i32,
            CV_8UC1,
            image.data.as_ptr() as *mut std::ffi::c_void,
            image.step,
        )?
    };
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
        // CameraInfo describes the camera, not the frame this node is about to
        // receive. If the JPEG is decoded at a fraction of its stored size, `k`
        // has to come down with it or every pose is scaled by the same factor
        // -- confidently, with nothing in the graph reporting an error.
        let decode_factor = config.decode_scale.divisor() as f64;
        node.create_subscription(sub_opts("~/input/camera_info"), move |msg: CameraInfo| {
            let k = golfcart_aruco_detector::scale_intrinsics(&msg.k, decode_factor);
            match Detector::new(geometry, params, &k, &msg.d, &msg.distortion_model) {
                Ok(detector) => {
                    let first = state.load().is_none();
                    state.store(Arc::new(Some(Arc::new(detector))));
                    if first {
                        log_info!(
                            NODE_NAME,
                            "calibration received: {}x{}, {} distortion coefficients ({})",
                            msg.width / decode_factor as u32,
                            msg.height / decode_factor as u32,
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

    // One subscription, one transport, chosen by parameter. The crate owns the
    // decode and the `CompressedImage.format` contract; this node only ever
    // sees grayscale pixels, whichever transport they arrived on.
    let _image_subscription = {
        let state = Arc::clone(&detector_state);
        let overlay_publisher = overlay_publisher.clone();
        let handle_frame = handle_frame.clone();
        subscribe_image(
            &node,
            "~/input/image",
            config.transport,
            sensor_qos,
            // Detection reads intensity only. Asking for one channel means a
            // colour JPEG never has its chroma reconstructed, rather than
            // building three channels and throwing two away.
            Target::Mono,
            // How much of the JPEG to decode. Distinct from detection_downscale
            // in what it costs: this throws pixels away before anything sees
            // them, so corner precision really does drop, where
            // detection_downscale keeps the full frame for the refinement.
            // Intrinsics are brought down by the same factor where CameraInfo
            // arrives, or every pose would be scaled by it.
            config.decode_scale,
            |message| log_error!(NODE_NAME, "{message}"),
            move |frame: Frame| {
                let loaded = state.load();
                let Some(detector) = loaded.as_ref().as_ref() else {
                    warn_no_calibration();
                    return;
                };
                let mat = match as_gray_mat(&frame.image) {
                    Ok(mat) => mat,
                    Err(error) => {
                        log_error!(NODE_NAME, "cannot read decoded image: {error:#}");
                        return;
                    }
                };
                let (width, height) = (frame.image.width as u32, frame.image.height as u32);
                handle_frame(detector, &mat, &frame.header, width, height);

                if let Some(publisher) = &overlay_publisher {
                    // The overlay is republished under the sensor's own header;
                    // nothing else of the original message is needed.
                    let original = Image {
                        header: frame.header.clone(),
                        ..Default::default()
                    };
                    if let Err(error) = publish_overlay(detector, &mat, &original, publisher) {
                        log_warn!(NODE_NAME, "overlay failed: {error:#}");
                    }
                }
            },
        )
        .map_err(|error| anyhow!("{error}"))?
    };

    log_info!(
        NODE_NAME,
        "subscribed on the {:?} transport, decoding at {:?}, detection downscale {}",
        config.transport,
        config.decode_scale,
        config.detector.detection_downscale
    );

    log_info!(NODE_NAME, "detector running");
    executor.spin(SpinOptions::default()).first_error()?;
    Ok(())
}
