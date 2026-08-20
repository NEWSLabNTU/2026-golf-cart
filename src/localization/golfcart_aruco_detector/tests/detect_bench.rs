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

//! Where the detector's CPU actually goes, and what each knob buys.
//!
//! Measured because the node costs ~2 cores for ONE camera at 30 fps, and the
//! JPEG decode it was blamed on is about 6 ms of that. This is a benchmark, so
//! it is `#[ignore]`d and prints rather than asserts:
//!
//! ```console
//! cd src/localization/golfcart_aruco_detector
//! cargo test --release --test detect_bench -- --ignored --nocapture
//! ```
//!
//! Every row reports the marker count as well as the time. A configuration that
//! is fast because it stopped seeing markers is not a speed-up, and without the
//! count in the same table that is easy to miss.

use anyhow::Result;
use golfcart_aruco_detector::{
    render, ArucoDictionary, BoardGeometry, CornerRefinement, Detector, DetectorParams,
    NUM_CORNERS,
};
use opencv::{
    core::{self as core_cv, Mat, Rect, Scalar, Size},
    imgproc,
    prelude::*,
};
use std::time::Instant;

const WIDTH: i32 = 1920;
const HEIGHT: i32 = 1280;
const ITERATIONS: usize = 20;

fn geometry() -> BoardGeometry {
    BoardGeometry {
        dictionary: ArucoDictionary::DICT_5X5_1000,
        marker_size_m: 0.384,
        border_bits: 1,
    }
}

/// The parameters the vehicle actually runs, from aruco_detector.param.yaml.
fn shipped_params() -> DetectorParams {
    let mut params = DetectorParams::default();
    params.corner_refinement.method = CornerRefinement::Subpix;
    params.corner_refinement.win_size = 5;
    params.corner_refinement.max_iterations = 30;
    params.corner_refinement.min_accuracy = 0.01;
    params.adaptive_thresh.win_size_min = 13;
    params.adaptive_thresh.win_size_max = 33;
    params.adaptive_thresh.win_size_step = 10;
    params.candidate_filter.min_marker_perimeter_rate = 0.01;
    params.candidate_filter.max_marker_perimeter_rate = 4.0;
    params.candidate_filter.error_correction_rate = 0.6;
    params.candidate_filter.min_marker_distance_rate = 0.05;
    params
}

fn intrinsics(width: i32, height: i32) -> [f64; 9] {
    let f = width as f64;
    [
        f,
        0.0,
        width as f64 / 2.0,
        0.0,
        f,
        height as f64 / 2.0,
        0.0,
        0.0,
        1.0,
    ]
}

/// A frame with three markers on it, at an apparent size a camera would see a
/// board at across a room.
///
/// `clutter` adds speckle noise. It is not decoration: on a clean white canvas
/// the adaptive threshold produces almost no contours, `_detectCandidates`
/// finds nothing to reject, and the benchmark measures a scene no camera ever
/// returns. The two rows are reported separately rather than averaged, because
/// the gap between them IS the finding.
fn scene(clutter: bool) -> Result<Mat> {
    let mut canvas = render::blank(WIDTH, HEIGHT)?;

    for (index, id) in [7u32, 23, 42].into_iter().enumerate() {
        let marker = render::render_marker(ArucoDictionary::DICT_5X5_1000, id, 140, 1, 20)?;
        let x = 200 + index as i32 * 520;
        let y = 420;
        let roi = Rect::new(x, y, marker.cols(), marker.rows());
        let mut target = Mat::roi(&canvas, roi)?;
        marker.copy_to(&mut target)?;
    }

    if clutter {
        let mut noise = Mat::new_rows_cols_with_default(
            HEIGHT,
            WIDTH,
            core_cv::CV_8UC1,
            Scalar::all(0.0),
        )?;
        // A fixed seed: a benchmark whose input changes between runs measures
        // the input as much as the code.
        let mut rng = core_cv::RNG::new(42)?;
        rng.fill(&mut noise, core_cv::RNG_NORMAL, &Scalar::all(128.0), &Scalar::all(45.0), false)?;
        let mut blurred = Mat::default();
        imgproc::gaussian_blur(
            &noise,
            &mut blurred,
            Size::new(3, 3),
            0.0,
            0.0,
            core_cv::BORDER_DEFAULT,
        )?;
        let mut mixed = Mat::default();
        core_cv::add_weighted(&canvas, 0.75, &blurred, 0.25, 0.0, &mut mixed, -1)?;
        canvas = mixed;
    }

    Ok(canvas)
}

/// A cluttered empty frame, so the floor is measured against the kind of image
/// a camera returns rather than against a white wall.
fn scene_background() -> Result<Mat> {
    let canvas = render::blank(WIDTH, HEIGHT)?;
    let mut noise =
        Mat::new_rows_cols_with_default(HEIGHT, WIDTH, core_cv::CV_8UC1, Scalar::all(0.0))?;
    let mut rng = core_cv::RNG::new(42)?;
    rng.fill(&mut noise, core_cv::RNG_NORMAL, &Scalar::all(128.0), &Scalar::all(45.0), false)?;
    let mut blurred = Mat::default();
    imgproc::gaussian_blur(&noise, &mut blurred, Size::new(3, 3), 0.0, 0.0, core_cv::BORDER_DEFAULT)?;
    let mut mixed = Mat::default();
    core_cv::add_weighted(&canvas, 0.75, &blurred, 0.25, 0.0, &mut mixed, -1)?;
    Ok(mixed)
}

fn time_it(label: &str, detector: &Detector, image: &Mat) -> Result<(f64, usize)> {
    // One warm-up pass: the first call through OpenCV's allocator and any
    // lazily built tables is not representative.
    let _ = detector.detect(image)?;
    let started = Instant::now();
    let mut found = 0;
    for _ in 0..ITERATIONS {
        found = detector.detect(image)?.len();
    }
    let ms = started.elapsed().as_secs_f64() * 1000.0 / ITERATIONS as f64;
    println!("    {label:<44} {ms:>7.1} ms   {found} marker(s)");
    Ok((ms, found))
}

fn build(image: &Mat, params: DetectorParams) -> Result<Detector> {
    Detector::new(
        geometry(),
        params,
        &intrinsics(image.cols(), image.rows()),
        &[0.0; 5],
        "plumb_bob",
    )
}

fn half(image: &Mat) -> Result<Mat> {
    let mut small = Mat::default();
    imgproc::resize(
        image,
        &mut small,
        Size::new(image.cols() / 2, image.rows() / 2),
        0.0,
        0.0,
        imgproc::INTER_AREA,
    )?;
    Ok(small)
}

#[test]
#[ignore = "benchmark, run explicitly with --ignored --nocapture"]
fn where_the_detection_time_goes() -> Result<()> {
    for clutter in [false, true] {
        let image = scene(clutter)?;
        println!(
            "\n  {} scene, {}x{}, three DICT_5X5_1000 markers at 140 px",
            if clutter { "CLUTTERED (speckle)" } else { "CLEAN (white)" },
            image.cols(),
            image.rows()
        );

        let baseline = shipped_params();
        time_it("shipped params", &build(&image, baseline)?, &image)?;

        // One adaptive-threshold scale instead of three. Each scale is a full
        // threshold pass plus findContours over the whole frame.
        let mut one_scale = shipped_params();
        one_scale.adaptive_thresh.win_size_max = 13;
        time_it("one threshold scale (13 only)", &build(&image, one_scale)?, &image)?;

        let mut two_scales = shipped_params();
        two_scales.adaptive_thresh.win_size_max = 23;
        time_it("two threshold scales (13, 23)", &build(&image, two_scales)?, &image)?;

        // OpenCV's default minimum. Ours is 0.01, which admits quads down to
        // roughly 14 px per side on a 1920-wide frame, and every one of them
        // reaches the identification step.
        let mut opencv_min_perimeter = shipped_params();
        opencv_min_perimeter.candidate_filter.min_marker_perimeter_rate = 0.03;
        time_it("min_marker_perimeter_rate 0.03", &build(&image, opencv_min_perimeter)?, &image)?;

        let mut no_refine = shipped_params();
        no_refine.corner_refinement.method = CornerRefinement::None;
        time_it("no corner refinement", &build(&image, no_refine)?, &image)?;

        let mut contour_refine = shipped_params();
        contour_refine.corner_refinement.method = CornerRefinement::Contour;
        time_it("contour corner refinement", &build(&image, contour_refine)?, &image)?;

        // Everything cheap at once, to see whether the knobs compose.
        let mut combined = shipped_params();
        combined.adaptive_thresh.win_size_max = 13;
        combined.candidate_filter.min_marker_perimeter_rate = 0.03;
        time_it("one scale + perimeter 0.03", &build(&image, combined)?, &image)?;

        // Half resolution, which is what the crate's scaled JPEG decode would
        // hand over. A quarter of the pixels; the markers are 70 px instead of
        // 140, so this row is also a detection-rate check.
        // Diagnostics: if the sweep width barely moves the total, the adaptive
        // threshold is not where the time goes, whatever intuition says.
        let mut many_scales = shipped_params();
        many_scales.adaptive_thresh.win_size_min = 3;
        many_scales.adaptive_thresh.win_size_max = 63;
        many_scales.adaptive_thresh.win_size_step = 2;
        time_it("31 threshold scales (3..63 step 2)", &build(&image, many_scales)?, &image)?;

        // How much of the total is OpenCV's detectMarkers, and how much is this
        // crate's undistort + PnP on top of it.
        {
            let detector = build(&image, shipped_params())?;
            let dictionary = ArucoDictionary::DICT_5X5_1000.to_opencv()?;
            let opencv_params = shipped_params().to_opencv(1)?;
            let mut corners = opencv::types::VectorOfMat::new();
            let mut ids = opencv::core::Vector::<i32>::new();
            let _ = opencv::aruco::detect_markers(
                &image, &dictionary, &mut corners, &mut ids, &opencv_params,
                &mut core_cv::no_array(), &mut core_cv::no_array(), &mut core_cv::no_array());
            let started = Instant::now();
            for _ in 0..ITERATIONS {
                opencv::aruco::detect_markers(
                    &image, &dictionary, &mut corners, &mut ids, &opencv_params,
                    &mut core_cv::no_array(), &mut core_cv::no_array(), &mut core_cv::no_array())?;
            }
            let ms = started.elapsed().as_secs_f64() * 1000.0 / ITERATIONS as f64;
            println!("    {:<44} {ms:>7.1} ms   {} marker(s)", "detect_markers alone (no undistort/PnP)", ids.len());
            let _ = detector;
        }

        // One adaptiveThreshold pass over the frame, for scale.
        {
            let mut out = Mat::default();
            let started = Instant::now();
            for _ in 0..ITERATIONS {
                imgproc::adaptive_threshold(&image, &mut out, 255.0,
                    imgproc::ADAPTIVE_THRESH_MEAN_C, imgproc::THRESH_BINARY_INV, 13, 7.0)?;
            }
            let ms = started.elapsed().as_secs_f64() * 1000.0 / ITERATIONS as f64;
            println!("    {:<44} {ms:>7.1} ms", "one adaptiveThreshold pass");
        }

        // The two-stage path: coarse detect on a reduced frame, corners refined
        // against the full one. This is the row that matters.
        for factor in [2, 3, 4] {
            let mut staged = shipped_params();
            staged.detection_downscale = factor;
            time_it(
                &format!("two-stage, detection_downscale {factor}"),
                &build(&image, staged)?,
                &image,
            )?;
        }

        // For reference: feeding a already-halved image straight through, which
        // is what a naive "just decode smaller" would do. Same coarse cost, but
        // the corners are never refined at full resolution.
        let small = half(&image)?;
        time_it("half image throughout (no full-res refine)", &build(&small, shipped_params())?, &small)?;

        // The trap. Narrowing the sweep AND reducing the image are not
        // independent: at half resolution the markers are 70 px, and a sweep
        // starting at 13 no longer finds them at all.
        let mut small_combined = shipped_params();
        small_combined.adaptive_thresh.win_size_max = 13;
        time_it("half image + one scale (LOSES MARKERS)", &build(&small, small_combined)?, &small)?;
    }
    Ok(())
}

/// What the two-stage path costs in corner precision.
///
/// Speed without this number is not a result: corner error is the direct input
/// noise of the pose solve, and with four corners per marker there is no
/// redundancy to average it away. Full-resolution detection is the reference,
/// not ground truth -- the question is whether refining against the full frame
/// recovers what the reduced detection gave up.
#[test]
#[ignore = "benchmark, run explicitly with --ignored --nocapture"]
fn what_the_two_stage_path_costs_in_precision() -> Result<()> {
    let image = scene(true)?;

    let reference = build(&image, shipped_params())?.detect(&image)?;
    println!("\n  reference: full resolution, {} marker(s)", reference.len());

    for factor in [2, 3, 4] {
        let mut staged = shipped_params();
        staged.detection_downscale = factor;
        let detections = build(&image, staged)?.detect(&image)?;

        let mut sum = 0.0f64;
        let mut worst: f64 = 0.0;
        let mut matched = 0;
        for marker in &detections {
            let Some(truth) = reference.iter().find(|other| other.id == marker.id) else {
                continue;
            };
            matched += 1;
            for (a, b) in marker.corners.iter().zip(truth.corners.iter()) {
                let dx = (a.x - b.x) as f64;
                let dy = (a.y - b.y) as f64;
                let error = (dx * dx + dy * dy).sqrt();
                sum += error * error;
                worst = worst.max(error);
            }
        }
        let rmse = if matched > 0 {
            (sum / (matched * NUM_CORNERS) as f64).sqrt()
        } else {
            f64::NAN
        };
        println!(
            "    downscale {factor}: {} marker(s), corner RMSE {rmse:.3} px, worst {worst:.3} px",
            detections.len()
        );
    }
    Ok(())
}

/// The apparent marker size each downscale factor stops seeing.
///
/// This is what the two-stage path actually trades away. Precision is recovered
/// by the full-resolution refinement, so the only real cost is that a marker too
/// small to survive the reduction is never found at all -- and a marker's
/// apparent size is its distance, so this table is a working range in disguise.
///
/// A 0.384 m marker at 1920 px wide with f = 1920 spans roughly 190 px at 4 m
/// and 95 px at 8 m.
#[test]
#[ignore = "benchmark, run explicitly with --ignored --nocapture"]
fn the_smallest_marker_each_downscale_can_still_find() -> Result<()> {
    println!();
    for factor in [1, 2, 3, 4] {
        let mut params = shipped_params();
        params.detection_downscale = factor;

        let mut floor = None;
        for size in (12..=200).step_by(2) {
            let mut canvas = scene_background()?;
            let marker =
                render::render_marker(ArucoDictionary::DICT_5X5_1000, 7, size, 1, size / 4)?;
            let roi = Rect::new(400, 400, marker.cols(), marker.rows());
            let mut target = Mat::roi(&canvas, roi)?;
            marker.copy_to(&mut target)?;
            drop(target);

            let detector = build(&canvas, params)?;
            if detector.detect(&canvas)?.len() == 1 {
                floor = Some(size);
                break;
            }
            let _ = &canvas;
        }
        match floor {
            Some(size) => println!("    downscale {factor}: finds markers down to {size} px"),
            None => println!("    downscale {factor}: found nothing up to 200 px"),
        }
    }
    Ok(())
}
