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

//! The subscriber side: transport hints, and image/`CameraInfo` pairing.
//!
//! `image_transport` is a C++ pluginlib system. rclrs cannot load its plugins
//! and has no intra-process comms either, so a Rust node has to own this
//! itself. What is worth copying from the C++ convention is not the plugin
//! machinery -- it is the two things a node actually consumes:
//!
//! - a **transport hint**, so switching a node between `raw` and `compressed`
//!   is configuration rather than a code change;
//! - a **camera subscriber**, which hands the callback an image and the
//!   `CameraInfo` that belongs with it, instead of leaving every node to
//!   hand-roll the pairing.
//!
//! Topic naming follows the same convention: the base topic is `image_raw`,
//! the compressed transport lives at `image_raw/compressed`, and `camera_info`
//! is a sibling of the base -- `.../left/image_raw` pairs with
//! `.../left/camera_info`.

use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use rclrs::{Node, QoSProfile, RclrsError, Subscription, SubscriptionOptions};
use sensor_msgs::msg::{CameraInfo, CompressedImage, Image};
use std_msgs::msg::Header;

use image_transport_codec::{
    decode::{DecodeError, DecodedImage, Decoder, Scale},
    format::{CompressedFormat, Target},
};

/// Which transport to subscribe on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Transport {
    /// `sensor_msgs/Image` on the base topic.
    Raw,
    /// `sensor_msgs/CompressedImage` on `<base>/compressed`.
    #[default]
    Compressed,
}

impl Transport {
    /// Parse a transport hint, as a node parameter would carry it.
    pub fn from_hint(hint: &str) -> Result<Self, TransportError> {
        match hint {
            "raw" => Ok(Transport::Raw),
            "compressed" => Ok(Transport::Compressed),
            other => Err(TransportError::UnknownHint(other.to_string())),
        }
    }

    /// The topic suffix this transport appends to the base topic.
    pub fn suffix(self) -> &'static str {
        match self {
            Transport::Raw => "",
            Transport::Compressed => "/compressed",
        }
    }

    /// Full topic name for a base topic.
    pub fn topic(self, base: &str) -> String {
        format!("{base}{}", self.suffix())
    }
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error(
        "unknown transport hint {0:?}; this crate implements \"raw\" and \
         \"compressed\". H.264/H.265 belong in ffmpeg_image_transport, which \
         uses its own message type, and compressedDepth is a separate transport \
         with a binary header in front of a PNG"
    )]
    UnknownHint(String),

    #[error(transparent)]
    Rclrs(#[from] RclrsError),

    #[error(transparent)]
    Decode(#[from] DecodeError),
}

/// `SubscriptionOptions` is `#[non_exhaustive]`, so it cannot be built with a
/// struct literal from outside rclrs; assigning the field after `new` is the
/// supported route and this keeps that detail in one place.
fn options(topic: &str, qos: QoSProfile) -> SubscriptionOptions<'_> {
    let mut options = SubscriptionOptions::new(topic);
    options.qos = qos;
    options
}

/// One frame handed to a callback: the publisher's header, and pixels in
/// whatever the subscription asked for.
#[derive(Debug, Clone)]
pub struct Frame {
    pub header: Header,
    pub image: DecodedImage,
    /// The `format` string this frame arrived with, parsed. `None` on the raw
    /// transport.
    ///
    /// Carried rather than discarded because it is the only record of what the
    /// publisher claimed, and a node that logs it once at startup can answer
    /// "is this camera writing the compound form or gscam's bare `jpeg`?"
    /// without anyone running `ros2 topic echo`.
    pub source_format: Option<CompressedFormat>,
    /// How long the decode took. Zero on the raw transport when no conversion
    /// was needed.
    pub decode_time: Duration,
}

/// A live image subscription. Dropping it unsubscribes.
///
/// Exactly one of the two inner subscriptions exists; which one is the whole
/// point of [`Transport`].
pub struct ImageSubscription {
    _raw: Option<Subscription<Image>>,
    _compressed: Option<Subscription<CompressedImage>>,
}

/// Subscribe to images on either transport, delivering `target` pixels.
///
/// `target` is what the callback wants, not what the publisher sends. A
/// [`Target::Mono`] request against a colour JPEG decodes one channel directly
/// and never builds the other two; against a raw `bgr8`/`rgb8` topic it
/// converts, because there is nothing cheaper to do with bytes that have
/// already been expanded.
pub fn subscribe_image<F>(
    node: &Node,
    base_topic: &str,
    transport: Transport,
    qos: QoSProfile,
    target: Target,
    scale: Scale,
    on_error: impl Fn(String) + Send + Sync + 'static,
    callback: F,
) -> Result<ImageSubscription, TransportError>
where
    F: Fn(Frame) + Send + Sync + 'static,
{
    let topic = transport.topic(base_topic);
    match transport {
        Transport::Compressed => {
            // One decoder for the life of the subscription: libjpeg keeps its
            // working buffers between frames, and rclrs delivers on one worker
            // so the mutex is uncontended in practice.
            let decoder = Mutex::new(Decoder::new()?.with_scale(scale));
            let reported = topic.clone();
            let subscription = node.create_subscription(
                options(&topic, qos),
                move |msg: CompressedImage| {
                    let format = CompressedFormat::parse(&msg.format);
                    let mut decoder = decoder.lock().unwrap();
                    // Check the format string first, then decode to what the
                    // caller wants. Both halves matter: skipping the first
                    // hands a PNG to a JPEG decoder, skipping the second
                    // decodes three channels to throw two away.
                    let started = Instant::now();
                    let decoded = format
                        .validate_codec()
                        .map_err(DecodeError::from)
                        .and_then(|()| decoder.decode_to(&msg.data, target));
                    let decode_time = started.elapsed();
                    match decoded {
                        Ok(image) => callback(Frame {
                            header: msg.header.clone(),
                            image,
                            source_format: Some(format),
                            decode_time,
                        }),
                        Err(error) => on_error(format!(
                            "{reported}: cannot decode a {} byte {:?} frame: {error}",
                            msg.data.len(),
                            msg.format
                        )),
                    }
                },
            )?;
            Ok(ImageSubscription { _raw: None, _compressed: Some(subscription) })
        }
        Transport::Raw => {
            let reported = topic.clone();
            let subscription = node.create_subscription(
                options(&topic, qos),
                move |msg: Image| {
                    let started = Instant::now();
                    let converted = raw_to_target(&msg, target);
                    let decode_time = started.elapsed();
                    match converted {
                    Ok(image) => callback(Frame {
                        header: msg.header.clone(),
                        image,
                        source_format: None,
                        decode_time,
                    }),
                    Err(error) => on_error(format!(
                        "{reported}: cannot read a {:?} frame: {error}",
                        msg.encoding
                    )),
                    }
                },
            )?;
            Ok(ImageSubscription { _raw: Some(subscription), _compressed: None })
        }
    }
}


#[derive(Debug, thiserror::Error)]
pub enum RawError {
    #[error("unsupported raw encoding {0:?}; handled: mono8, bgr8, rgb8, bgra8, rgba8")]
    UnsupportedEncoding(String),
    #[error("{encoding} {width}x{height} needs {want} bytes, message carries {got}")]
    ShortBuffer {
        encoding: String,
        width: u32,
        height: u32,
        want: usize,
        got: usize,
    },
}

/// Convert a raw `Image` to the requested target.
///
/// Kept separate from the subscription so it is testable without a ROS graph.
pub fn raw_to_target(msg: &Image, target: Target) -> Result<DecodedImage, RawError> {
    let (channels, blue_first) = match msg.encoding.as_str() {
        "mono8" => (1usize, false),
        "bgr8" => (3, true),
        "rgb8" => (3, false),
        "bgra8" => (4, true),
        "rgba8" => (4, false),
        other => return Err(RawError::UnsupportedEncoding(other.to_string())),
    };
    let (width, height) = (msg.width as usize, msg.height as usize);
    // `step` may exceed width*channels: rows can be padded, and a publisher is
    // entitled to do that.
    let step = if msg.step as usize >= width * channels {
        msg.step as usize
    } else {
        width * channels
    };
    let want = step * height;
    if msg.data.len() < want {
        return Err(RawError::ShortBuffer {
            encoding: msg.encoding.clone(),
            width: msg.width,
            height: msg.height,
            want,
            got: msg.data.len(),
        });
    }

    let out_channels = target.channels();
    let out_step = width * out_channels;
    let mut data = vec![0u8; out_step * height];

    for y in 0..height {
        let src = &msg.data[y * step..y * step + width * channels];
        let dst = &mut data[y * out_step..(y + 1) * out_step];
        match (channels, out_channels) {
            (1, 1) => dst.copy_from_slice(src),
            (1, 3) => {
                for (x, px) in src.iter().enumerate() {
                    dst[x * 3..x * 3 + 3].copy_from_slice(&[*px, *px, *px]);
                }
            }
            (_, 1) => {
                // ITU-R BT.601 luma, the same weights and the same rounding
                // OpenCV's COLOR_BGR2GRAY uses, so a node that switches from
                // cvtColor to this does not shift its detections by a grey
                // level.
                for x in 0..width {
                    let px = &src[x * channels..x * channels + 3];
                    let (b, g, r) = if blue_first {
                        (px[0] as u32, px[1] as u32, px[2] as u32)
                    } else {
                        (px[2] as u32, px[1] as u32, px[0] as u32)
                    };
                    dst[x] = ((r * 4899 + g * 9617 + b * 1868 + 8192) >> 14) as u8;
                }
            }
            (_, 3) => {
                // Out is BGR by definition of Target::Colour.
                for x in 0..width {
                    let px = &src[x * channels..x * channels + 3];
                    let (b, g, r) = if blue_first {
                        (px[0], px[1], px[2])
                    } else {
                        (px[2], px[1], px[0])
                    };
                    dst[x * 3..x * 3 + 3].copy_from_slice(&[b, g, r]);
                }
            }
            _ => unreachable!("out_channels is 1 or 3"),
        }
    }

    Ok(DecodedImage {
        width,
        height,
        step: out_step,
        // The caller asked for this, so name it, rather than echoing an
        // encoding the pixels no longer have.
        encoding: target.wire_name().to_string(),
        channels: out_channels,
        data,
    })
}

/// How a frame is matched with the `CameraInfo` that describes it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum InfoPolicy {
    /// Use the most recently received `CameraInfo`, whatever its stamp.
    ///
    /// Right for a fixed camera whose intrinsics do not change, and the reason
    /// it is the default: it survives a driver that publishes `CameraInfo` once
    /// at startup, or at a lower rate than images, both of which happen.
    #[default]
    Latest,
    /// Require an exact stamp match, and drop frames that do not have one.
    ///
    /// Matches C++ `CameraSubscriber`, which synchronises exact times. Correct
    /// when intrinsics really do vary per frame -- a zoom, or a rectifier
    /// upstream -- and a silent frame-dropper otherwise.
    ExactStamp,
}

/// An image subscription paired with its `CameraInfo`.
///
/// This is what every Rust node that needs intrinsics was hand-rolling.
pub struct CameraSubscription {
    _image: ImageSubscription,
    _info: Subscription<CameraInfo>,
}

/// Sibling `camera_info` topic for a base image topic.
///
/// `.../left/image_raw` -> `.../left/camera_info`, matching `image_transport`.
pub fn camera_info_topic(base_topic: &str) -> String {
    match base_topic.rsplit_once('/') {
        Some((parent, _)) if !parent.is_empty() => format!("{parent}/camera_info"),
        _ => "camera_info".to_string(),
    }
}

/// Subscribe to an image topic and its `CameraInfo`, delivering both together.
#[allow(clippy::too_many_arguments)]
pub fn subscribe_camera<F>(
    node: &Node,
    base_topic: &str,
    transport: Transport,
    qos: QoSProfile,
    target: Target,
    scale: Scale,
    policy: InfoPolicy,
    on_error: impl Fn(String) + Send + Sync + 'static,
    on_waiting: impl Fn() + Send + Sync + 'static,
    callback: F,
) -> Result<CameraSubscription, TransportError>
where
    F: Fn(Frame, Arc<CameraInfo>) + Send + Sync + 'static,
{
    // A short ring rather than one slot: with ExactStamp the info for frame N
    // can arrive either side of the image, and one slot loses the race half the
    // time. Ten frames is a third of a second at 30 Hz.
    const INFO_RING: usize = 10;

    let infos: Arc<Mutex<Vec<Arc<CameraInfo>>>> = Arc::new(Mutex::new(Vec::new()));

    let info_topic = camera_info_topic(base_topic);
    let sink = Arc::clone(&infos);
    let info_subscription = node.create_subscription(
        options(&info_topic, qos),
        move |msg: CameraInfo| {
            let mut infos = sink.lock().unwrap();
            infos.push(Arc::new(msg));
            if infos.len() > INFO_RING {
                infos.remove(0);
            }
        },
    )?;

    let source = Arc::clone(&infos);
    let image_subscription = subscribe_image(
        node,
        base_topic,
        transport,
        qos,
        target,
        scale,
        on_error,
        move |frame| {
            let infos = source.lock().unwrap();
            let matched = match policy {
                InfoPolicy::Latest => infos.last().cloned(),
                InfoPolicy::ExactStamp => infos
                    .iter()
                    .find(|info| {
                        info.header.stamp.sec == frame.header.stamp.sec
                            && info.header.stamp.nanosec == frame.header.stamp.nanosec
                    })
                    .cloned(),
            };
            drop(infos);
            match matched {
                Some(info) => callback(frame, info),
                // Not an error: a camera that has not published its calibration
                // yet is a startup state, and it is also blocker 1 in
                // docs/roadmaps/2-camera-image-pipeline.md -- a camera that
                // never publishes one looks exactly like this forever, so the
                // node above needs to say so rather than sit silent.
                None => on_waiting(),
            }
        },
    )?;

    Ok(CameraSubscription {
        _image: image_subscription,
        _info: info_subscription,
    })
}
