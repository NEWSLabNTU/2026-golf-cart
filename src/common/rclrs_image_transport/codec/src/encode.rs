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

//! JPEG encode.
//!
//! Not on the vehicle's critical path -- the cameras encode in hardware on
//! NVJPG, and re-encoding in software on the host would undo the point of the
//! whole pipeline. This exists so the crate can produce the fixtures its own
//! round-trip tests read, and for the occasional tool that has raw pixels and
//! needs to put them on a compressed topic.

use crate::format::{CompressedFormat, Target};

#[derive(Debug, thiserror::Error)]
pub enum EncodeError {
    #[error("libjpeg: {0}")]
    Jpeg(#[from] turbojpeg::Error),
    #[error("buffer holds {got} bytes, {want} needed for {width}x{height} at {channels} channel(s)")]
    ShortBuffer {
        got: usize,
        want: usize,
        width: usize,
        height: usize,
        channels: usize,
    },
}

/// Quality below which marker corners start to move.
///
/// JPEG ringing lands on high-contrast edges, which on an ArUco board is
/// exactly what subpixel refinement measures, and corner error becomes pose
/// error. Chroma is a different matter: at 4:2:0 luma is not subsampled at all
/// and the detector decodes grayscale, so the chroma loss costs that path
/// nothing.
pub const MIN_LOCALIZATION_QUALITY: i32 = 85;

pub struct Encoder {
    quality: i32,
    subsamp: turbojpeg::Subsamp,
}

impl Default for Encoder {
    fn default() -> Self {
        Self {
            // Matches the cameras' `nvjpegenc quality=90`, so a fixture encoded
            // here is comparable with one off the wire.
            quality: 90,
            subsamp: turbojpeg::Subsamp::Sub2x2,
        }
    }
}

impl Encoder {
    pub fn new(quality: i32) -> Self {
        Self {
            quality,
            ..Default::default()
        }
    }

    /// Encode interleaved pixels and return the payload with the `format`
    /// string that describes it.
    ///
    /// `source_encoding` is echoed verbatim into the first field, which every
    /// subscriber copies into `Image.encoding`. For [`Target::Colour`] the
    /// pixels must be BGR, because the third field is the literal `bgr8` and
    /// that substring is what makes C++ subscribers swap channels on request.
    pub fn encode(
        &self,
        pixels: &[u8],
        width: usize,
        height: usize,
        target: Target,
        source_encoding: &str,
    ) -> Result<(Vec<u8>, CompressedFormat), EncodeError> {
        let channels = target.channels();
        let want = width * height * channels;
        if pixels.len() < want {
            return Err(EncodeError::ShortBuffer {
                got: pixels.len(),
                want,
                width,
                height,
                channels,
            });
        }

        let (pixel_format, format) = match target {
            Target::Mono => (
                turbojpeg::PixelFormat::GRAY,
                CompressedFormat::jpeg_mono(source_encoding),
            ),
            Target::Colour => (
                turbojpeg::PixelFormat::BGR,
                CompressedFormat::jpeg_colour(source_encoding),
            ),
        };

        let image = turbojpeg::Image {
            pixels: &pixels[..want],
            width,
            pitch: width * channels,
            height,
            format: pixel_format,
        };
        // Grayscale input has no chroma to subsample, and asking for 4:2:0
        // there is an error rather than a no-op.
        let subsamp = match target {
            Target::Mono => turbojpeg::Subsamp::Gray,
            Target::Colour => self.subsamp,
        };
        let buf = turbojpeg::compress(image, self.quality, subsamp)?;
        Ok((buf.to_vec(), format))
    }
}
