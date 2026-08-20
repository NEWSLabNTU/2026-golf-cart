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

//! The `CompressedImage.format` contract and the JPEG codec behind it.
//!
//! Split out of `rclrs_image_transport` with **no ROS dependency at all**, for
//! one reason: the message crates it would otherwise pull in do not exist on
//! crates.io -- colcon-cargo-ros2 substitutes generated bindings through
//! `[patch.crates-io]` at build time. A crate that names them cannot resolve a
//! lock file outside an ament workspace, and so cannot be tested with plain
//! `cargo test`. Everything here can:
//!
//! ```console
//! $ cd codec && cargo test
//! ```
//!
//! The parts that do need message types -- transport hints, the camera
//! subscriber -- live in the parent crate.

pub mod decode;
pub mod encode;
pub mod format;

pub use decode::{DecodeError, DecodedImage, Decoder, Scale};
pub use encode::{EncodeError, Encoder, MIN_LOCALIZATION_QUALITY};
pub use format::{Codec, CompressedFormat, FormatError, Resolved, Target};
