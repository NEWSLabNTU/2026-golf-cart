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

//! Read what the C++ plugin actually wrote.
//!
//! The fixtures in `tests/fixtures/` were produced by running
//! `compressed_image_transport`'s own republisher over a known image; see
//! `scripts/make_fixtures.py`. They are committed so this test needs no ROS
//! graph, and regenerated only when the plugin version changes.
//!
//! The image is chosen so a channel swap cannot hide: the left half is
//! saturated blue, the right half saturated red, with a green ramp down the
//! rows. Any implementation that reads `"rgb8; jpeg compressed bgr8"` as "the
//! target says bgr8, decode BGR" produces an image with those halves exchanged,
//! and every assertion about colour below fails.

use std::path::{Path, PathBuf};

use image_transport_codec::{CompressedFormat, Decoder, Encoder, Target};

const WIDTH: usize = 64;
const HEIGHT: usize = 48;
/// JPEG at quality 80 on a 64-pixel-wide image with a hard vertical edge rings
/// noticeably. Sampling away from the edge and allowing this much slack tests
/// the channel order, which is what is under test, without pretending the
/// codec is lossless.
const TOLERANCE: i32 = 40;

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn read(name: &str, extension: &str) -> Vec<u8> {
    let path = fixtures().join(format!("{name}.{extension}"));
    std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

fn declared_format(name: &str) -> String {
    let meta = String::from_utf8(read(name, "json")).unwrap();
    // Deliberately not pulling in a JSON crate for one field in a test.
    let key = "\"format\": \"";
    let start = meta.find(key).expect("fixture json has a format field") + key.len();
    let end = start + meta[start..].find('"').unwrap();
    meta[start..end].to_string()
}

/// Pixel at (x, y) from an interleaved buffer.
fn pixel(data: &[u8], channels: usize, x: usize, y: usize) -> &[u8] {
    let offset = (y * WIDTH + x) * channels;
    &data[offset..offset + channels]
}

fn close(actual: u8, expected: u8) -> bool {
    (actual as i32 - expected as i32).abs() <= TOLERANCE
}

#[test]
fn the_cpp_publisher_writes_the_compound_form_we_expect() {
    // If these three strings ever change, the contract this crate implements
    // has moved and the rest of the file is measuring the wrong thing.
    assert_eq!(declared_format("cpp_bgr8"), "bgr8; jpeg compressed bgr8");
    assert_eq!(declared_format("cpp_rgb8"), "rgb8; jpeg compressed bgr8");
    assert_eq!(declared_format("cpp_mono8"), "mono8; jpeg compressed mono8");
}

#[test]
fn a_cpp_bgr8_frame_decodes_to_bgr8_pixels() {
    let format = CompressedFormat::parse(&declared_format("cpp_bgr8"));
    let mut decoder = Decoder::new().unwrap();
    let image = decoder.decode(&format, &read("cpp_bgr8", "jpg")).unwrap();

    assert_eq!((image.width, image.height), (WIDTH, HEIGHT));
    assert_eq!(image.encoding, "bgr8");
    assert_eq!(image.channels, 3);

    // Left half is blue: in bgr8 byte order that is the FIRST channel.
    let left = pixel(&image.data, 3, 8, 24);
    assert!(close(left[0], 255) && close(left[2], 0), "left {left:?}");
    let right = pixel(&image.data, 3, 56, 24);
    assert!(close(right[0], 0) && close(right[2], 255), "right {right:?}");
}

#[test]
fn a_cpp_rgb8_frame_decodes_to_rgb8_pixels_despite_a_bgr8_target() {
    // The trap, and the reason this file exists. The payload is BGR and the
    // target field says bgr8, but the first field says rgb8, so the pixels
    // handed to the caller must be RGB.
    let format = CompressedFormat::parse(&declared_format("cpp_rgb8"));
    assert_eq!(format.target, Some(Target::Colour));
    assert!(format.descriptor_says_bgr);
    assert!(format.resolve(3).unwrap().emit_rgb_order);

    let mut decoder = Decoder::new().unwrap();
    let image = decoder.decode(&format, &read("cpp_rgb8", "jpg")).unwrap();
    assert_eq!(image.encoding, "rgb8");

    // Left half is blue: in rgb8 byte order that is the THIRD channel. Read
    // against the previous test -- same picture, opposite indices.
    let left = pixel(&image.data, 3, 8, 24);
    assert!(close(left[2], 255) && close(left[0], 0), "left {left:?}");
    let right = pixel(&image.data, 3, 56, 24);
    assert!(close(right[2], 0) && close(right[0], 255), "right {right:?}");
}

#[test]
fn a_cpp_mono8_frame_decodes_to_one_channel() {
    let format = CompressedFormat::parse(&declared_format("cpp_mono8"));
    let mut decoder = Decoder::new().unwrap();
    let image = decoder.decode(&format, &read("cpp_mono8", "jpg")).unwrap();

    assert_eq!(image.channels, 1);
    assert_eq!(image.encoding, "mono8");
    assert_eq!(image.step, WIDTH);
    // The source is a top-to-bottom ramp, so row 40 is brighter than row 4.
    let top = pixel(&image.data, 1, 32, 4)[0];
    let bottom = pixel(&image.data, 1, 32, 40)[0];
    assert!(bottom > top + 100, "ramp lost: {top} -> {bottom}");
}

#[test]
fn a_colour_frame_can_be_decoded_straight_to_grey() {
    // The detector's path: never build the two channels it is going to discard.
    let mut decoder = Decoder::new().unwrap();
    let grey = decoder
        .decode_to(&read("cpp_bgr8", "jpg"), Target::Mono)
        .unwrap();
    assert_eq!(grey.channels, 1);
    assert_eq!((grey.width, grey.height), (WIDTH, HEIGHT));

    // Same picture through the colour path, converted afterwards, agrees.
    let colour = decoder
        .decode_to(&read("cpp_bgr8", "jpg"), Target::Colour)
        .unwrap();
    let bgr = pixel(&colour.data, 3, 8, 24);
    let luma = (bgr[2] as u32 * 4899 + bgr[1] as u32 * 9617 + bgr[0] as u32 * 1868 + 8192) >> 14;
    assert!(close(pixel(&grey.data, 1, 8, 24)[0], luma as u8));
}

#[test]
fn scaled_decode_returns_a_smaller_image_of_the_same_scene() {
    let mut decoder = Decoder::new()
        .unwrap()
        .with_scale(image_transport_codec::Scale::Half);
    let image = decoder
        .decode_to(&read("cpp_mono8", "jpg"), Target::Mono)
        .unwrap();
    assert_eq!((image.width, image.height), (WIDTH / 2, HEIGHT / 2));
    assert_eq!(image.step, WIDTH / 2);
    assert_eq!(image.data.len(), WIDTH / 2 * (HEIGHT / 2));
}

#[test]
fn what_we_encode_is_what_the_cpp_publisher_would_have_written() {
    // The other direction of the contract. The payload cannot be compared byte
    // for byte -- different libjpeg settings -- but the format string can, and
    // the format string is the whole interface.
    let raw = read("cpp_bgr8", "raw");
    let (payload, format) = Encoder::default()
        .encode(&raw, WIDTH, HEIGHT, Target::Colour, "bgr8")
        .unwrap();
    assert_eq!(format.to_wire(), declared_format("cpp_bgr8"));

    // And it reads back as itself.
    let mut decoder = Decoder::new().unwrap();
    let image = decoder.decode(&format, &payload).unwrap();
    assert_eq!(image.encoding, "bgr8");
    let left = pixel(&image.data, 3, 8, 24);
    assert!(close(left[0], 255) && close(left[2], 0), "left {left:?}");

    let grey_raw = read("cpp_mono8", "raw");
    let (_, grey_format) = Encoder::default()
        .encode(&grey_raw, WIDTH, HEIGHT, Target::Mono, "mono8")
        .unwrap();
    assert_eq!(grey_format.to_wire(), declared_format("cpp_mono8"));
}

#[test]
fn gscams_bare_form_survives_a_real_payload() {
    // Every bag this project has recorded carries this string; if the fallback
    // is wrong, replay is wrong.
    let format = CompressedFormat::parse("jpeg");
    let mut decoder = Decoder::new().unwrap();

    let colour = decoder.decode(&format, &read("cpp_bgr8", "jpg")).unwrap();
    assert_eq!(colour.encoding, "bgr8");
    assert_eq!(colour.channels, 3);

    let grey = decoder.decode(&format, &read("cpp_mono8", "jpg")).unwrap();
    assert_eq!(grey.encoding, "mono8");
    assert_eq!(grey.channels, 1);
}
