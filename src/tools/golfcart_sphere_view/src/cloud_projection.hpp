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

#ifndef GOLFCART_SPHERE_VIEW__CLOUD_PROJECTION_HPP_
#define GOLFCART_SPHERE_VIEW__CLOUD_PROJECTION_HPP_

#include <OgreColourValue.h>
#include <OgreVector3.h>

namespace golfcart_sphere_view
{

/// How a return is placed relative to the sphere.
enum class CloudPlacement
{
  /// Snapped to the sphere radius. Range is discarded, so what remains is the
  /// direction the sensor reports -- the comparison a camera can answer.
  Angular,
  /// Left where it was measured. Range is kept, so a translation error between
  /// sensors shows as depth disagreement rather than being projected away.
  Metric,
};

/// Place a point expressed in the centre frame.
///
/// A return at the origin has no direction to preserve, so Angular leaves it
/// alone rather than dividing by zero -- it lands at the centre where it is
/// visibly wrong, which is the honest outcome for a degenerate return.
Ogre::Vector3 placePoint(const Ogre::Vector3 & point, double radius, CloudPlacement placement);

/// Blue through red across [0, 1], clamped outside it.
///
/// Values outside the range are clamped rather than wrapped: a saturated return
/// should look like the top of the scale, not like the bottom of it.
Ogre::ColourValue rainbow(double fraction);

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__CLOUD_PROJECTION_HPP_
