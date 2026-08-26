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

#ifndef GOLFCART_SPHERE_VIEW__RAW_IMAGE_HPP_
#define GOLFCART_SPHERE_VIEW__RAW_IMAGE_HPP_

#include <QImage>
#include <cstdint>
#include <string>
#include <vector>

namespace golfcart_sphere_view
{

/// Turn a sensor_msgs/Image payload into a QImage.
///
/// Returns a null image and sets `reason` when the encoding is not one this
/// display can draw, or when the buffer is shorter than its own dimensions
/// claim. Both are worth reporting rather than asserting: a viewer that
/// crashes on an unexpected encoding is worse than one that says which
/// encoding it met.
///
/// The result owns its pixels. Aliasing the caller's buffer would be cheaper
/// and wrong -- the frame is a worker-local copy that goes away, and Qt's
/// implicit sharing would hand the render thread a dangling pointer instead of
/// an error.
QImage rawImageToQImage(
  const std::vector<uint8_t> & bytes, uint32_t width, uint32_t height, uint32_t step,
  const std::string & encoding, std::string & reason);

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__RAW_IMAGE_HPP_
