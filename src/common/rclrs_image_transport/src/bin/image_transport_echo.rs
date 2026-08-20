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

//! What is actually on a camera topic, and what it costs to decode.
//!
//! `ros2 topic echo --field format` tells you the format string. It does not
//! tell you whether this crate can decode the payload, what the pixels come out
//! as, or how long that takes -- which is what you want to know before pointing
//! a detector at a camera.
//!
//! ```console
//! ros2 run rclrs_image_transport image_transport_echo --ros-args \
//!   -p base_topic:=/sensing/camera/left/image_raw \
//!   -p transport:=compressed -p target:=mono
//! ```
//!
//! It also exercises the subscriber API against a real graph, which is the
//! only way to find out that a callback signature or a topic name is wrong.

use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc,
};

use rclrs::{
    log_error, log_info, log_warn, Context, CreateBasicExecutor, QoSProfile, RclrsErrorFilter,
    SpinOptions,
};
use rclrs_image_transport::{
    camera_info_topic, subscribe_camera, subscribe_image, Frame, InfoPolicy, Scale, Target,
    Transport,
};

const NODE_NAME: &str = "image_transport_echo";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let context = Context::default_from_env()?;
    let mut executor = context.create_basic_executor();
    let node = executor.create_node(NODE_NAME)?;

    let base_topic = node
        .declare_parameter::<Arc<str>>("base_topic")
        .default("image_raw".into())
        .mandatory()?
        .get();
    let transport = Transport::from_hint(
        &node
            .declare_parameter::<Arc<str>>("transport")
            .default("compressed".into())
            .mandatory()?
            .get(),
    )?;
    let target = match node
        .declare_parameter::<Arc<str>>("target")
        .default("mono".into())
        .mandatory()?
        .get()
        .as_ref()
    {
        "mono" => Target::Mono,
        "colour" | "color" => Target::Colour,
        other => {
            log_error!(NODE_NAME, "target must be \"mono\" or \"colour\", got {other:?}");
            return Ok(());
        }
    };
    let scale = match node
        .declare_parameter::<Arc<str>>("scale")
        .default("full".into())
        .mandatory()?
        .get()
        .as_ref()
    {
        "full" => Scale::Full,
        "half" => Scale::Half,
        "quarter" => Scale::Quarter,
        "eighth" => Scale::Eighth,
        other => {
            log_error!(NODE_NAME, "unknown scale {other:?}");
            return Ok(());
        }
    };
    // Pairing with CameraInfo is the other half of what a consumer needs, and
    // whether it ever arrives is an open question on this vehicle -- see
    // blocker 1 in docs/roadmaps/2-camera-image-pipeline.md. Off by default so
    // this tool still reports on a camera that publishes no intrinsics.
    let with_camera_info = node
        .declare_parameter("with_camera_info")
        .default(false)
        .mandatory()?
        .get();

    // Sensor data: best effort, keep last. A tool that changes the QoS a real
    // consumer would use is measuring a different topic.
    let qos = QoSProfile::sensor_data_default().keep_last(1);

    log_info!(
        NODE_NAME,
        "watching {} on the {transport:?} transport, decoding to {target:?} at {scale:?}",
        transport.topic(&base_topic)
    );
    if with_camera_info {
        log_info!(NODE_NAME, "pairing with {}", camera_info_topic(&base_topic));
    }

    let frames = Arc::new(AtomicU64::new(0));
    let report = {
        let frames = Arc::clone(&frames);
        move |frame: &Frame| {
            let count = frames.fetch_add(1, Ordering::Relaxed);
            // Every frame for the first three, then one a second at 30 Hz. The
            // first frames are what you are waiting for; after that this is a
            // rate check, not a log.
            if count >= 3 && count % 30 != 0 {
                return;
            }
            let image = &frame.image;
            let micros = frame.decode_time.as_micros();
            match &frame.source_format {
                Some(format) => log_info!(
                    NODE_NAME,
                    "#{count} format={:?} -> codec {:?}, target {:?}; decoded {}x{}x{} {} in {micros} us",
                    format.to_wire(),
                    format.codec,
                    format.target,
                    image.width,
                    image.height,
                    image.channels,
                    image.encoding
                ),
                None => log_info!(
                    NODE_NAME,
                    "#{count} raw -> {}x{}x{} {} in {micros} us",
                    image.width,
                    image.height,
                    image.channels,
                    image.encoding
                ),
            }
        }
    };

    let on_error = |message: String| log_error!(NODE_NAME, "{message}");

    // Both branches keep their subscription alive for the life of main; drop it
    // and the topic goes quiet.
    let _subscriptions: (Option<_>, Option<_>) = if with_camera_info {
        let report = report.clone();
        (
            None,
            Some(subscribe_camera(
                &node,
                &base_topic,
                transport,
                qos,
                target,
                scale,
                InfoPolicy::Latest,
                on_error,
                || log_warn!(NODE_NAME, "images arriving, no CameraInfo yet"),
                move |frame, info| {
                    report(&frame);
                    // Printed once: intrinsics do not change, and the point of
                    // asking for them is to prove they arrive at all.
                    static SEEN: AtomicBool = AtomicBool::new(false);
                    if !SEEN.swap(true, Ordering::Relaxed) {
                        log_info!(
                            NODE_NAME,
                            "CameraInfo paired: {}x{}, {} distortion coefficients ({})",
                            info.width,
                            info.height,
                            info.d.len(),
                            info.distortion_model
                        );
                    }
                },
            )?),
        )
    } else {
        (
            Some(subscribe_image(
                &node,
                &base_topic,
                transport,
                qos,
                target,
                scale,
                on_error,
                move |frame| report(&frame),
            )?),
            None,
        )
    };

    executor.spin(SpinOptions::default()).first_error()?;
    Ok(())
}
