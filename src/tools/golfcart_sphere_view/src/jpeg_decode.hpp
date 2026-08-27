// Copyright 2026 NEWSLab, National Taiwan University
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

#ifndef GOLFCART_SPHERE_VIEW__JPEG_DECODE_HPP_
#define GOLFCART_SPHERE_VIEW__JPEG_DECODE_HPP_

#include <QImage>
#include <cstdint>
#include <string>
#include <vector>

namespace golfcart_sphere_view
{

/// Scale factor the decoder will apply, as a numerator over eight.
///
/// libjpeg can emit at N/8 of the stored size while decoding, skipping the
/// inverse DCT work for coefficients it will not use. That is a real saving,
/// unlike decoding at full size and scaling afterwards, which is what Qt's
/// QImageReader::setScaledSize does -- measured at 22 to 28% against the four
/// times fewer pixels a half-size decode actually touches.
///
/// Only the eighths libjpeg accelerates are offered. `width_limit` of zero
/// means full size.
int jpegScaleNumerator(int stored_width, int width_limit);

/// Decode a JPEG, optionally at a fraction of its stored size.
///
/// Returns a null image and sets `reason` when the data is not a JPEG this
/// library can read, which is the caller's cue to fall back to Qt -- a
/// CompressedImage may carry PNG, and this display should draw it rather than
/// refuse it.
QImage decodeJpeg(
  const std::vector<uint8_t> & data, int width_limit, std::string & reason);

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__JPEG_DECODE_HPP_
