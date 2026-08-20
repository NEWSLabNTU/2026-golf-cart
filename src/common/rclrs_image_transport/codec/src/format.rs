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

//! `sensor_msgs/CompressedImage.format`, as `compressed_image_transport` writes
//! and reads it.
//!
//! The message definition says nothing about this field. The convention is
//! whatever the C++ plugin does, so this module reproduces that behaviour
//! rather than inventing a cleaner one -- a Rust publisher a C++ subscriber
//! misreads is worse than no Rust publisher.
//!
//! Publisher side, from the Humble sources:
//!
//! ```text
//! compressed.format  = message.encoding;      // "bgr8"
//! compressed.format += "; jpeg compressed ";
//! compressed.format += targetFormat;          // "bgr8" colour, "mono8" mono
//! ```
//!
//! Subscriber side, splitting on the first `;`:
//!
//! | input | behaviour |
//! |---|---|
//! | first field | copied verbatim into `Image.encoding` |
//! | second field contains `compressed bgr` | BGR to RGB/RGBA/BGRA conversion |
//! | second field contains `jpeg` and a 16-bit encoding | `convertTo(CV_16U, 256)` |
//! | no `;` at all | guess by channel count: 1 -> `mono8`, 3 -> `bgr8`, else error |
//!
//! That last row is not a legacy curiosity. gscam writes a bare `"jpeg"`, so
//! every bag this project has recorded carries it, and a crate that cannot read
//! it cannot replay our own data.

use std::fmt;

/// What the payload bytes are compressed with.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Codec {
    Jpeg,
    /// Recognised and refused. `compressedDepth` is a *different* transport --
    /// a binary header prefixed to a PNG payload -- so a PNG here is either a
    /// colour PNG we have chosen not to implement, or a depth frame on the
    /// wrong topic. Both want an error, not a decode attempt.
    Png,
    /// Recognised and refused, same reasoning as [`Codec::Png`].
    Tiff,
    Unknown(String),
}

impl Codec {
    fn from_descriptor(descriptor: &str) -> Self {
        // Substring matching, case sensitive, because that is what the C++
        // subscriber does: it greps the descriptor with `std::string::find`.
        // Tokenising, or folding case, would accept strings the C++ side
        // rejects -- and a Rust node that reads more formats than its C++
        // counterpart is a divergence waiting to be discovered in the field.
        let lower = descriptor;
        if lower.contains("jpeg") || lower.contains("jpg") {
            Codec::Jpeg
        } else if lower.contains("png") {
            Codec::Png
        } else if lower.contains("tiff") || lower.contains("tif") {
            Codec::Tiff
        } else {
            Codec::Unknown(descriptor.trim().to_string())
        }
    }

    fn wire_name(&self) -> &str {
        match self {
            Codec::Jpeg => "jpeg",
            Codec::Png => "png",
            Codec::Tiff => "tiff",
            Codec::Unknown(other) => other,
        }
    }
}

/// The pixel layout the compressed payload actually holds, i.e. the third field
/// of the compound form.
///
/// Only two values are legal on the wire. `Colour` is written `bgr8` and
/// nothing else -- see [`FormatError::DishonestColourTarget`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    /// `bgr8`: three interleaved channels, blue first.
    Colour,
    /// `mono8`: one channel.
    Mono,
}

impl Target {
    /// The literal that goes on the wire.
    pub fn wire_name(self) -> &'static str {
        match self {
            Target::Colour => "bgr8",
            Target::Mono => "mono8",
        }
    }

    /// Channels per pixel once decoded.
    pub fn channels(self) -> usize {
        match self {
            Target::Colour => 3,
            Target::Mono => 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum FormatError {
    #[error(
        "colour target must be the literal \"bgr8\", got {0:?}: the C++ subscriber \
         greps the descriptor for \"compressed bgr\" to decide whether to swap \
         channels, so any other spelling silently transposes red and blue"
    )]
    DishonestColourTarget(String),

    #[error("{0} is recognised but not implemented; only jpeg is")]
    UnsupportedCodec(String),

    #[error("unrecognised compressed format {0:?}")]
    UnknownCodec(String),

    #[error(
        "no target in the format string and {0} channels in the payload: the \
         channel-count fallback handles 1 and 3 only"
    )]
    UndecidableChannelCount(usize),

    #[error("encoding {encoding}: {reason}")]
    UnsupportedEncoding {
        encoding: String,
        reason: &'static str,
    },
}

/// A parsed `CompressedImage.format`.
///
/// Round-trips: `parse(s).to_wire()` reproduces `s` for every string this
/// project emits, and for gscam's bare `"jpeg"`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompressedFormat {
    /// First field, copied verbatim into `Image.encoding` on decode. `None`
    /// for the bare form, where the subscriber has to guess.
    pub source_encoding: Option<String>,
    pub codec: Codec,
    /// Third field. `None` for the bare form.
    pub target: Option<Target>,
    /// True when the descriptor contains the literal `compressed bgr`, which is
    /// the exact substring the C++ subscriber tests. Kept separately from
    /// `target` because a decoder must reproduce the C++ decision, not a
    /// tidier one derived from it.
    pub descriptor_says_bgr: bool,
}

impl CompressedFormat {
    /// What a Rust publisher should write for a colour JPEG.
    ///
    /// `source_encoding` is the encoding of the image before compression and is
    /// echoed verbatim by every subscriber into `Image.encoding`; for a camera
    /// publishing colour that is `"bgr8"`, and the result is the identity case
    /// `"bgr8; jpeg compressed bgr8"` -- byte-identical to what the C++
    /// publisher produces, and no channel swap anywhere.
    pub fn jpeg_colour(source_encoding: &str) -> Self {
        Self {
            source_encoding: Some(source_encoding.to_string()),
            codec: Codec::Jpeg,
            target: Some(Target::Colour),
            descriptor_says_bgr: true,
        }
    }

    /// What a Rust publisher should write for a grayscale JPEG.
    pub fn jpeg_mono(source_encoding: &str) -> Self {
        Self {
            source_encoding: Some(source_encoding.to_string()),
            codec: Codec::Jpeg,
            target: Some(Target::Mono),
            descriptor_says_bgr: false,
        }
    }

    /// Build from arbitrary parts, refusing the colour spelling that reads as
    /// honest and decodes wrong.
    ///
    /// `"rgb8; jpeg compressed rgb8"` is the trap: the payload really is BGR
    /// (that is all libjpeg was handed), the C++ subscriber finds no
    /// `compressed bgr` in the descriptor, applies no swap, and labels BGR
    /// pixels `rgb8`. Nothing warns. Only the literal `bgr8` is accepted here,
    /// which is why the public constructors above take a [`Target`] rather than
    /// a string.
    pub fn new(
        source_encoding: &str,
        codec: Codec,
        target_literal: &str,
    ) -> Result<Self, FormatError> {
        let target = match target_literal {
            "bgr8" => Target::Colour,
            "mono8" => Target::Mono,
            other => return Err(FormatError::DishonestColourTarget(other.to_string())),
        };
        Ok(Self {
            source_encoding: Some(source_encoding.to_string()),
            codec,
            target: Some(target),
            descriptor_says_bgr: target == Target::Colour,
        })
    }

    /// Parse a `format` field. Never fails: an unrecognised codec parses to
    /// [`Codec::Unknown`] and is refused later, at decode, where the error can
    /// name the topic.
    pub fn parse(format: &str) -> Self {
        let Some((first, rest)) = format.split_once(';') else {
            // The bare form. gscam's `"jpeg"` lands here, and so does anything
            // else without a semicolon.
            return Self {
                source_encoding: None,
                codec: Codec::from_descriptor(format),
                target: None,
                descriptor_says_bgr: false,
            };
        };

        let descriptor = rest.trim();
        // The C++ subscriber tests for this exact substring and nothing else,
        // case sensitively.
        let descriptor_says_bgr = descriptor.contains("compressed bgr");

        // The target is the last whitespace-separated token, when it is one of
        // the two legal spellings. Anything else leaves `target` unset and the
        // channel-count fallback decides, which is also what C++ effectively
        // does: it never reads the token, it only greps.
        let target = match descriptor.split_whitespace().last() {
            Some("bgr8") => Some(Target::Colour),
            Some("mono8") => Some(Target::Mono),
            _ => None,
        };

        Self {
            source_encoding: Some(first.trim().to_string()),
            codec: Codec::from_descriptor(descriptor),
            target,
            descriptor_says_bgr,
        }
    }

    /// Refuse anything this crate does not decode, naming it.
    ///
    /// PNG and TIFF are recognised rather than lumped in with nonsense: a PNG
    /// here most likely means a `compressedDepth` frame on the wrong topic,
    /// which is a different transport with a binary header in front of the
    /// payload, and saying so is more use than "unknown format".
    pub fn validate_codec(&self) -> Result<(), FormatError> {
        match &self.codec {
            Codec::Jpeg => Ok(()),
            Codec::Png => Err(FormatError::UnsupportedCodec("png".into())),
            Codec::Tiff => Err(FormatError::UnsupportedCodec("tiff".into())),
            Codec::Unknown(other) => Err(FormatError::UnknownCodec(other.clone())),
        }
    }

    /// Render back to the wire.
    pub fn to_wire(&self) -> String {
        match (&self.source_encoding, self.target) {
            (Some(encoding), Some(target)) => format!(
                "{encoding}; {} compressed {}",
                self.codec.wire_name(),
                target.wire_name()
            ),
            // The bare form: no separator, so no encoding and no target can be
            // carried even if we knew them.
            _ => self.codec.wire_name().to_string(),
        }
    }

    /// Decide what to decode to, given what the payload turns out to contain.
    ///
    /// `payload_channels` is read from the JPEG header, not guessed, and is
    /// only consulted for the bare form -- exactly the C++ fallback: 1 channel
    /// is `mono8`, 3 is `bgr8`, anything else is an error.
    ///
    /// The channel-order half of this is the part that is easy to get wrong.
    /// The C++ subscriber decodes the payload to BGR, then reverts the
    /// publisher's colour transformation to match the encoding it is about to
    /// declare:
    ///
    /// ```text
    /// "rgb8; jpeg compressed bgr8"  ->  imdecode gives BGR, cvtColor BGR2RGB,
    ///                                   Image.encoding = "rgb8"
    /// ```
    ///
    /// That string is not hypothetical -- it is what the C++ plugin itself
    /// emits for an `rgb8` source image, verified by running it (see
    /// `scripts/make_fixtures.py`). A decoder that stops at "the target says
    /// bgr8, so decode BGR" hands back BGR pixels labelled `rgb8`, and red and
    /// blue are transposed with nothing to warn anyone.
    pub fn resolve(&self, payload_channels: usize) -> Result<Resolved, FormatError> {
        self.validate_codec()?;

        let target = match self.target {
            Some(target) => target,
            None => match payload_channels {
                1 => Target::Mono,
                3 => Target::Colour,
                other => return Err(FormatError::UndecidableChannelCount(other)),
            },
        };

        // The first field is copied verbatim by the C++ subscriber, whatever it
        // says. Reproduce that; do not "correct" it to match the target.
        let Some(encoding) = self.source_encoding.clone() else {
            // The bare form. The C++ subscriber never enters its colour branch
            // here, so no channel order is reverted: the payload comes out as
            // it went in.
            return Ok(Resolved {
                target,
                encoding: target.wire_name().to_string(),
                emit_rgb_order: false,
            });
        };

        // Everything below is the colour-order revert, and it only applies to
        // encodings C++ `image_encodings::isColor` calls colour.
        let emit_rgb_order = match ColourEncoding::classify(&encoding) {
            ColourEncoding::NotColour => false,
            // Flip exactly when the wanted order differs from the published
            // one: decoding with a BGR pixel format returns the bytes in the
            // order the publisher fed the encoder, and the descriptor names
            // that order.
            ColourEncoding::Rgb => self.descriptor_says_bgr,
            ColourEncoding::Bgr => !self.descriptor_says_bgr,
            ColourEncoding::Unsupported(reason) => return Err(reason),
        };
        // Read that pair once more, because the polarity is not obvious.
        // Decoding with a BGR pixel format returns the bytes in the order the
        // *publisher* fed the encoder, which the descriptor names. So the
        // decoder has to flip exactly when the wanted order differs from the
        // published one:
        //
        //   encoding  descriptor        flip?
        //   bgr8      compressed bgr    no    (identity, our own publisher)
        //   rgb8      compressed bgr    yes   (what the C++ plugin emits)
        //   bgr8      compressed rgb    yes
        //   rgb8      compressed rgb    no
        //
        // `emit_rgb_order` above is `true` for exactly the two flip rows.

        Ok(Resolved {
            target,
            encoding,
            emit_rgb_order,
        })
    }
}

impl fmt::Display for CompressedFormat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.to_wire())
    }
}

/// A [`CompressedFormat`] with the fallback applied: what to decode to, what
/// channel order to emit, and what to write into `Image.encoding` afterwards.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub target: Target,
    /// Goes into `Image.encoding` verbatim.
    pub encoding: String,
    /// Emit `R,G,B` rather than `B,G,R`, so the pixels match [`Self::encoding`].
    ///
    /// Costs nothing: libjpeg writes either order on request, where the C++
    /// subscriber pays a `cvtColor` pass for the same result.
    pub emit_rgb_order: bool,
}

/// How the first field of a format string classifies for the colour-order
/// revert. Mirrors C++ `sensor_msgs::image_encodings`.
enum ColourEncoding {
    /// `mono8`, or anything `isColor` says no to.
    NotColour,
    Rgb,
    Bgr,
    /// Colour, but out of this crate's 8-bit three-channel range.
    Unsupported(FormatError),
}

impl ColourEncoding {
    fn classify(encoding: &str) -> Self {
        match encoding {
            "bgr8" => ColourEncoding::Bgr,
            "rgb8" => ColourEncoding::Rgb,
            // Four-channel and 16-bit colour are legal in the C++ transport --
            // it widens with `convertTo(CV_16U, 256)` and adds an alpha channel
            // with `cvtColor` -- and are refused here by name rather than
            // silently returning three 8-bit channels under a label that
            // promises otherwise.
            "bgra8" | "rgba8" | "bgra16" | "rgba16" => {
                ColourEncoding::Unsupported(FormatError::UnsupportedEncoding {
                    encoding: encoding.to_string(),
                    reason: "four-channel colour is not implemented; \
                             this crate decodes three 8-bit channels",
                })
            }
            "bgr16" | "rgb16" => ColourEncoding::Unsupported(FormatError::UnsupportedEncoding {
                encoding: encoding.to_string(),
                reason: "16-bit colour is not implemented; the C++ transport \
                         widens 8-bit JPEG samples with convertTo(CV_16U, 256)",
            }),
            _ => ColourEncoding::NotColour,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_case_round_trips() {
        let wire = "bgr8; jpeg compressed bgr8";
        let parsed = CompressedFormat::parse(wire);
        assert_eq!(parsed.source_encoding.as_deref(), Some("bgr8"));
        assert_eq!(parsed.codec, Codec::Jpeg);
        assert_eq!(parsed.target, Some(Target::Colour));
        assert!(parsed.descriptor_says_bgr);
        assert_eq!(parsed.to_wire(), wire);
        assert_eq!(CompressedFormat::jpeg_colour("bgr8").to_wire(), wire);
    }

    #[test]
    fn mono_round_trips() {
        let wire = "mono8; jpeg compressed mono8";
        let parsed = CompressedFormat::parse(wire);
        assert_eq!(parsed.target, Some(Target::Mono));
        assert!(!parsed.descriptor_says_bgr);
        assert_eq!(parsed.to_wire(), wire);
        assert_eq!(CompressedFormat::jpeg_mono("mono8").to_wire(), wire);
    }

    #[test]
    fn gscam_bare_form_is_legal_and_falls_back_by_channel_count() {
        let parsed = CompressedFormat::parse("jpeg");
        assert_eq!(parsed.codec, Codec::Jpeg);
        assert_eq!(parsed.source_encoding, None);
        assert_eq!(parsed.target, None);
        assert_eq!(parsed.to_wire(), "jpeg");

        assert_eq!(parsed.resolve(3).unwrap().target, Target::Colour);
        assert_eq!(parsed.resolve(3).unwrap().encoding, "bgr8");
        assert!(!parsed.resolve(3).unwrap().emit_rgb_order);
        assert_eq!(parsed.resolve(1).unwrap().target, Target::Mono);
        assert_eq!(parsed.resolve(1).unwrap().encoding, "mono8");
        assert_eq!(
            parsed.resolve(4),
            Err(FormatError::UndecidableChannelCount(4))
        );
    }

    #[test]
    fn the_compound_form_wins_over_the_channel_count() {
        // A mono8 target on a 3-channel payload is a publisher bug, but the
        // C++ subscriber trusts the string, so we do too. Silent disagreement
        // between the two implementations is the thing being prevented.
        let parsed = CompressedFormat::parse("mono8; jpeg compressed mono8");
        assert_eq!(parsed.resolve(3).unwrap().target, Target::Mono);
    }

    #[test]
    fn the_first_field_is_copied_verbatim_and_drags_the_channel_order_with_it() {
        // This exact string is what the C++ plugin writes for an rgb8 source.
        // The payload is BGR, the declared encoding is rgb8, so the decode has
        // to come out RGB -- the whole point of `emit_rgb_order`.
        let parsed = CompressedFormat::parse("rgb8; jpeg compressed bgr8");
        let resolved = parsed.resolve(3).unwrap();
        assert_eq!(resolved.encoding, "rgb8");
        assert!(resolved.emit_rgb_order);

        // The identity case does not flip.
        let identity = CompressedFormat::parse("bgr8; jpeg compressed bgr8");
        assert!(!identity.resolve(3).unwrap().emit_rgb_order);

        // And a publisher that really did encode RGB-ordered bytes flips the
        // other way round.
        let rgb_payload = CompressedFormat::parse("bgr8; jpeg compressed rgb8");
        assert!(rgb_payload.resolve(3).unwrap().emit_rgb_order);
    }

    #[test]
    fn alpha_and_16_bit_colour_are_refused_by_name() {
        let alpha = CompressedFormat::parse("rgba8; jpeg compressed bgr8").resolve(3);
        assert!(matches!(
            alpha,
            Err(FormatError::UnsupportedEncoding { ref encoding, .. }) if encoding == "rgba8"
        ));
        let wide = CompressedFormat::parse("rgb16; jpeg compressed bgr8").resolve(3);
        assert!(matches!(
            wide,
            Err(FormatError::UnsupportedEncoding { ref encoding, .. }) if encoding == "rgb16"
        ));
    }

    #[test]
    fn a_dishonest_colour_target_cannot_be_constructed() {
        assert_eq!(
            CompressedFormat::new("rgb8", Codec::Jpeg, "rgb8"),
            Err(FormatError::DishonestColourTarget("rgb8".into()))
        );
        assert!(CompressedFormat::new("bgr8", Codec::Jpeg, "bgr8").is_ok());
    }

    #[test]
    fn png_and_tiff_parse_and_are_refused() {
        assert_eq!(
            CompressedFormat::parse("bgr8; png compressed bgr8").resolve(3),
            Err(FormatError::UnsupportedCodec("png".into()))
        );
        assert_eq!(
            CompressedFormat::parse("tiff").resolve(3),
            Err(FormatError::UnsupportedCodec("tiff".into()))
        );
    }

    #[test]
    fn nonsense_is_reported_as_unknown_not_guessed_at() {
        assert_eq!(
            CompressedFormat::parse("h264").resolve(3),
            Err(FormatError::UnknownCodec("h264".into()))
        );
    }

    #[test]
    fn leading_whitespace_in_the_descriptor_is_ignored() {
        // The C++ publisher writes "; jpeg compressed bgr8" with that leading
        // space, so trimming the descriptor is required, not cosmetic.
        let parsed = CompressedFormat::parse("bgr8;   jpeg compressed bgr8");
        assert_eq!(parsed.codec, Codec::Jpeg);
        assert_eq!(parsed.target, Some(Target::Colour));
        assert!(parsed.descriptor_says_bgr);
    }

    #[test]
    fn case_is_significant_because_it_is_significant_in_cpp() {
        // "JPEG" is not "jpeg". A C++ subscriber refuses this string, so this
        // one does too: reading more than the reference implementation is a
        // divergence, not a kindness.
        let parsed = CompressedFormat::parse("bgr8; JPEG compressed BGR8");
        assert!(matches!(parsed.codec, Codec::Unknown(_)));
        assert!(!parsed.descriptor_says_bgr);
    }
}
