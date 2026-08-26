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

#include "raw_image.hpp"

namespace golfcart_sphere_view
{

QImage rawImageToQImage(
  const std::vector<uint8_t> & bytes, uint32_t width, uint32_t height, uint32_t step,
  const std::string & encoding, std::string & reason)
{
  QImage::Format format = QImage::Format_Invalid;
  if (encoding == "rgb8") {
    format = QImage::Format_RGB888;
  } else if (encoding == "bgr8") {
    format = QImage::Format_BGR888;
  } else if (encoding == "mono8" || encoding == "8UC1") {
    format = QImage::Format_Grayscale8;
  } else if (encoding == "rgba8") {
    format = QImage::Format_RGBA8888;
  } else if (encoding == "bgra8") {
    format = QImage::Format_ARGB32;
  } else {
    // Bayer and YUV land here. Debayering belongs in a driver or in image_proc,
    // not in a viewer that would be guessing the pattern.
    reason = "unsupported encoding '" + encoding + "'";
    return QImage();
  }

  if (width == 0 || height == 0) {
    reason = "image has no size";
    return QImage();
  }
  const auto required = static_cast<std::size_t>(step) * static_cast<std::size_t>(height);
  if (step == 0 || bytes.size() < required) {
    reason = "buffer is shorter than step x height";
    return QImage();
  }

  const QImage aliased(
    bytes.data(), static_cast<int>(width), static_cast<int>(height), static_cast<int>(step),
    format);
  return aliased.copy();
}

}  // namespace golfcart_sphere_view
