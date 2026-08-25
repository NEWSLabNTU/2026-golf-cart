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

#include "cloud_projection.hpp"

#include <algorithm>
#include <cmath>

namespace golfcart_sphere_view
{

Ogre::Vector3 placePoint(
  const Ogre::Vector3 & point, double radius, CloudPlacement placement)
{
  if (placement == CloudPlacement::Metric) {
    return point;
  }
  const Ogre::Real length = point.length();
  if (length < 1e-6f) {
    return point;
  }
  return point * (static_cast<Ogre::Real>(radius) / length);
}

Ogre::ColourValue rainbow(double fraction)
{
  fraction = std::clamp(fraction, 0.0, 1.0);
  // Hue from 240 degrees (blue) down to 0 (red), at full saturation and value.
  // Written out rather than going through Ogre's HSB helper so the mapping is
  // visible to a reader deciding whether a colour means what they think.
  const double hue = (1.0 - fraction) * 4.0;
  const int band = static_cast<int>(std::floor(hue)) % 6;
  const auto remainder = static_cast<float>(hue - std::floor(hue));

  switch (band) {
    case 0: return Ogre::ColourValue(1.0f, remainder, 0.0f);
    case 1: return Ogre::ColourValue(1.0f - remainder, 1.0f, 0.0f);
    case 2: return Ogre::ColourValue(0.0f, 1.0f, remainder);
    case 3: return Ogre::ColourValue(0.0f, 1.0f - remainder, 1.0f);
    default: return Ogre::ColourValue(0.0f, 0.0f, 1.0f);
  }
}

}  // namespace golfcart_sphere_view
