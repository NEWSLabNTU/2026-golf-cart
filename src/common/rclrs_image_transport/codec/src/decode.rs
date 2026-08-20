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

//! JPEG decode, via libjpeg-turbo.
//!
//! Two things here are not reachable through the C++ `image_transport`
//! subscriber, which always hands you a full-resolution `cv::Mat` of whatever
//! the format string named:
//!
//! - **grayscale decode**, which skips chroma upsampling entirely;
//! - **DCT-scaled decode** at 1/2, 1/4 or 1/8, which does less IDCT work rather
//!   than resizing after a full decode.
//!
//! Measured on this AGX Orin, one 1920x1280 quality-90 4:2:0 frame:
//!
//! | path | ms |
//! |---|---|
//! | `turbojpeg` gray, full | 5.3 |
//! | `turbojpeg` BGR, full | 9.1 |
//! | `turbojpeg` gray, 1/2 | 3.1 |
//! | `turbojpeg` gray, 1/4 | 2.9 |
//! | OpenCV `imdecode(IMREAD_GRAYSCALE)` | 4.9 |
//!
//! Read the last row before assuming this module is a speed win: OpenCV's
//! `IMREAD_GRAYSCALE` already decodes grayscale directly, so replacing it buys
//! roughly nothing per frame. What it buys is the format contract, one fewer
//! OpenCV feature to link, and the scaled path.

use crate::format::{CompressedFormat, FormatError, Target};

#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error(transparent)]
    Format(#[from] FormatError),
    #[error("libjpeg: {0}")]
    Jpeg(#[from] turbojpeg::Error),
    #[error("empty payload")]
    Empty,
}

/// A decoded frame, in the shape `sensor_msgs/Image` wants.
#[derive(Debug, Clone)]
pub struct DecodedImage {
    pub width: usize,
    pub height: usize,
    /// Bytes per row. Equal to `width * channels`; there is no row padding.
    pub step: usize,
    /// Goes into `Image.encoding` verbatim. Comes from the format string's
    /// first field when there is one, and from the channel-count fallback when
    /// there is not.
    pub encoding: String,
    pub channels: usize,
    pub data: Vec<u8>,
}

/// How much of the IDCT to actually run.
///
/// libjpeg-turbo supports denominators up to 8; these are the three that are
/// both useful and exact fractions of the 8x8 DCT block.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Scale {
    #[default]
    Full,
    Half,
    Quarter,
    Eighth,
}

impl Scale {
    fn factor(self) -> turbojpeg::ScalingFactor {
        match self {
            Scale::Full => turbojpeg::ScalingFactor::ONE,
            Scale::Half => turbojpeg::ScalingFactor::new(1, 2),
            Scale::Quarter => turbojpeg::ScalingFactor::new(1, 4),
            Scale::Eighth => turbojpeg::ScalingFactor::new(1, 8),
        }
    }
}

/// A reusable decoder.
///
/// Hold one per subscription rather than constructing per frame: libjpeg's
/// internal buffers then stay allocated across frames.
pub struct Decoder {
    inner: turbojpeg::Decompressor,
    scale: Scale,
}

impl Decoder {
    pub fn new() -> Result<Self, DecodeError> {
        Ok(Self {
            inner: turbojpeg::Decompressor::new()?,
            scale: Scale::Full,
        })
    }

    /// Decode at a fraction of full resolution.
    ///
    /// Measure before adopting this for marker detection: it trades corner
    /// precision for CPU, and corner precision is pose accuracy. The standard
    /// trick is detect at 1/2 and refine corners at full resolution, which
    /// costs two decodes and only pays when detection dominates.
    pub fn with_scale(mut self, scale: Scale) -> Self {
        self.scale = scale;
        self
    }

    pub fn scale(&self) -> Scale {
        self.scale
    }

    /// Decode according to the format string, applying the C++ subscriber's
    /// rules including the bare-form channel-count fallback.
    pub fn decode(
        &mut self,
        format: &CompressedFormat,
        data: &[u8],
    ) -> Result<DecodedImage, DecodeError> {
        if data.is_empty() {
            return Err(DecodeError::Empty);
        }
        // The fallback has to know what is actually in the payload, so read it
        // from the JPEG header rather than trusting a string that is missing
        // precisely because nobody wrote it.
        let (_, _, payload_channels) = self.probe(data)?;
        let resolved = format.resolve(payload_channels)?;
        let pixel_format = match (resolved.target, resolved.emit_rgb_order) {
            (Target::Mono, _) => turbojpeg::PixelFormat::GRAY,
            (Target::Colour, false) => turbojpeg::PixelFormat::BGR,
            // Free: libjpeg writes either order. The C++ subscriber pays a
            // whole `cvtColor` pass to reach the same pixels.
            (Target::Colour, true) => turbojpeg::PixelFormat::RGB,
        };
        let decoded = self.decode_pixels(data, pixel_format, resolved.target.channels())?;
        Ok(DecodedImage {
            encoding: resolved.encoding,
            ..decoded
        })
    }

    /// Decode to a chosen target whatever the format string says.
    ///
    /// This is the ArUco detector's path: a colour JPEG decoded straight to one
    /// channel, no chroma upsampling and no conversion pass afterwards.
    /// `encoding` on the result is the target's own name, not the publisher's
    /// first field, because the caller has overridden what the publisher asked
    /// for.
    pub fn decode_to(&mut self, data: &[u8], target: Target) -> Result<DecodedImage, DecodeError> {
        let (pixel_format, channels) = match target {
            Target::Mono => (turbojpeg::PixelFormat::GRAY, 1),
            Target::Colour => (turbojpeg::PixelFormat::BGR, 3),
        };
        let decoded = self.decode_pixels(data, pixel_format, channels)?;
        Ok(DecodedImage {
            // The caller asked for this, so name it, rather than echoing an
            // encoding the pixels no longer have.
            encoding: target.wire_name().to_string(),
            ..decoded
        })
    }

    fn decode_pixels(
        &mut self,
        data: &[u8],
        pixel_format: turbojpeg::PixelFormat,
        channels: usize,
    ) -> Result<DecodedImage, DecodeError> {
        if data.is_empty() {
            return Err(DecodeError::Empty);
        }
        let factor = self.scale.factor();
        self.inner.set_scaling_factor(factor)?;

        // `read_header` reports the stored dimensions; the scaling factor is
        // applied by the decompress call, so size the output buffer for the
        // scaled result here.
        let header = self.inner.read_header(data)?;
        let width = factor.scale(header.width);
        let height = factor.scale(header.height);

        let step = width * channels;

        let mut image = turbojpeg::Image {
            pixels: vec![0u8; step * height],
            width,
            pitch: step,
            height,
            format: pixel_format,
        };
        self.inner.decompress(data, image.as_deref_mut())?;

        Ok(DecodedImage {
            width,
            height,
            step,
            // Overwritten by the callers above, which know what to call this.
            encoding: String::new(),
            channels,
            data: image.pixels,
        })
    }

    /// Stored width, height and channel count, without decoding pixels.
    ///
    /// Cheap -- headers only. Useful for choosing a scale, and for the one-line
    /// startup log that says what a topic is actually carrying.
    pub fn probe(&mut self, data: &[u8]) -> Result<(usize, usize, usize), DecodeError> {
        let header = self.inner.read_header(data)?;
        let channels = if header.subsamp == turbojpeg::Subsamp::Gray {
            1
        } else {
            3
        };
        Ok((header.width, header.height, channels))
    }
}
