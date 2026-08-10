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

#ifndef GOLFCART_ARUCO_LOCALIZER__TAG_FRAME_HPP_
#define GOLFCART_ARUCO_LOCALIZER__TAG_FRAME_HPP_

#include <Eigen/Core>

#include <array>
#include <cstddef>

namespace golfcart::aruco_localizer
{

/// Index of each corner within a corner array, in OpenCV's ordering.
///
/// Every corner array in this package -- tag-local model corners, detected
/// image corners, surveyed map corners -- uses this order. There is exactly one
/// definition of it, here, and `test_tag_frame` pins it against OpenCV itself.
///
/// This is not pedantry. A corner permutation is a silent 90 or 180 degree pose
/// error that still converges and still reports a small residual, so nothing
/// downstream will complain. The one repository we are borrowing this pipeline
/// from defined corner order twice, in two languages, with nothing checking
/// that the two agreed.
enum Corner : std::size_t
{
  kTopLeft = 0,
  kTopRight = 1,
  kBottomRight = 2,
  kBottomLeft = 3,
};

/// Number of corners on a square marker.
inline constexpr std::size_t kNumCorners = 4;

/// Corner positions in the tag's own frame.
///
/// The tag frame is OpenCV's marker frame: origin at the marker centre,
/// **x right, y up, z out of the printed face toward a viewer looking at it**.
///
/// That deliberately violates REP-103's x-forward preference. Matching OpenCV
/// exactly is worth more here, because these coordinates are handed directly to
/// PnP and every other convention in this data path is OpenCV's already.
///
/// Ordering is `Corner`: top-left, top-right, bottom-right, bottom-left, as seen
/// by that viewer. Note this traverses the square *clockwise* in a right-handed
/// x-right / y-up frame -- which is counter-clockwise in image coordinates,
/// where y points down. Saying "counter-clockwise" without naming the viewing
/// side is how this gets implemented backwards, so the order is given
/// explicitly rather than described.
///
/// @param marker_size Edge length of the black marker square, in metres. This
///   is the *marker*, not the board it is printed on; for a board generated with
///   a white border and a marker-to-square ratio, it is the inner black square.
///   Getting it wrong scales every range estimate linearly.
inline std::array<Eigen::Vector3d, kNumCorners> tagLocalCorners(const double marker_size)
{
  const double h = 0.5 * marker_size;
  return {
    Eigen::Vector3d{-h, +h, 0.0},  // top-left
    Eigen::Vector3d{+h, +h, 0.0},  // top-right
    Eigen::Vector3d{+h, -h, 0.0},  // bottom-right
    Eigen::Vector3d{-h, -h, 0.0},  // bottom-left
  };
}

}  // namespace golfcart::aruco_localizer

#endif  // GOLFCART_ARUCO_LOCALIZER__TAG_FRAME_HPP_
