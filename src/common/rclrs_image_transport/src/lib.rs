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

//! `image_transport`, for the parts of it a Rust node cannot reach.
//!
//! `image_transport` is C++ pluginlib. rclrs cannot load its plugins, and has
//! no intra-process comms either, so the Rust side has to own both the codec
//! and the image/`CameraInfo` pairing. This crate is that, and nothing more: it
//! implements the JPEG transport and the subscriber conventions, and refuses
//! everything else by name.
//!
//! # The contract
//!
//! `CompressedImage.format` is the whole interface between a publisher and a
//! subscriber, and the message definition does not specify it. The convention
//! is whatever `compressed_image_transport` does, so
//! [`image_transport_codec::format`] reproduces that behaviour rather than a
//! tidier one. Two facts drive every decision there:
//!
//! - the colour target field must be the literal `bgr8`, because that substring
//!   is what a C++ subscriber greps for to decide whether to swap channels;
//! - the bare form -- a `format` of just `"jpeg"`, with no `;` -- is legal, is
//!   what gscam writes, and is in every bag this project has recorded.
//!
//! # Layout
//!
//! | crate | needs ROS | holds |
//! |---|---|---|
//! | `image_transport_codec` (`codec/`) | no | the format contract, decode, encode |
//! | `rclrs_image_transport` (this) | yes | transport hints, image and camera subscriptions |
//!
//! The split is what lets the contract be unit-tested with plain `cargo test`:
//! the message crates only exist inside an ament workspace, so a crate naming
//! them cannot resolve a lock file anywhere else.
//!
//! # What is deliberately not here
//!
//! - **H.264/H.265 in `CompressedImage`.** The ecosystem answer is
//!   `ffmpeg_image_transport`, which uses its own message type precisely
//!   because `CompressedImage` is the wrong container for an inter-frame codec.
//! - **`compressedDepth`.** A separate transport: a binary header prefixed to a
//!   PNG payload, not a `format` string variant.
//! - **PNG and TIFF.** Parsed, named, and refused.

pub mod ros;

pub use image_transport_codec::{
    decode, encode, format, Codec, CompressedFormat, DecodeError, DecodedImage, Decoder,
    EncodeError, Encoder, FormatError, Resolved, Scale, Target, MIN_LOCALIZATION_QUALITY,
};

pub use ros::{
    camera_info_topic, subscribe_camera, subscribe_image, CameraSubscription, Frame,
    ImageSubscription, InfoPolicy, RawError, Transport, TransportError,
};
