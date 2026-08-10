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

#ifndef GOLFCART_ARUCO_LOCALIZER__TAG_MAP_HPP_
#define GOLFCART_ARUCO_LOCALIZER__TAG_MAP_HPP_

#include <golfcart_aruco_localizer/tag_frame.hpp>

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <array>
#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

/// One surveyed board.
struct TagPose
{
  std::uint32_t id{0};
  /// Pose of the tag frame in the map frame. Tag frame convention is
  /// `tag_frame.hpp`: x right, y up, z out of the printed face.
  Eigen::Isometry3d pose{Eigen::Isometry3d::Identity()};
  /// Marker edge length in metres -- the black square, not the board.
  double marker_size{0.0};
  /// 1-sigma position uncertainty of this board's surveyed pose, metres.
  /// Becomes the board's weight in the solve, so a carefully measured anchor
  /// legitimately outweighs a roughly placed one.
  double position_stddev{0.0};
};

/// Provenance of the survey. Recorded because `stated_accuracy` is the ceiling
/// on the whole system's accuracy -- no amount of vision quality recovers from
/// a poorly measured map -- and because knowing the instrument is what makes
/// that number auditable later.
struct TagMapSurvey
{
  std::string date;
  std::string method;
  double stated_accuracy{0.0};  // [m] 1-sigma
};

struct TagMap
{
  std::string frame_id;
  TagMapSurvey survey;
  std::string dictionary;
  /// Ordered so iteration is deterministic across runs; diagnostics that name
  /// boards are much easier to compare when the order does not shuffle.
  std::map<std::uint32_t, TagPose> tags;
};

struct TagMapOptions
{
  /// Max distance a surveyed corner may sit from the plane fitted through all
  /// four before the board is rejected. A non-planar quad has no well-defined
  /// orientation, so accepting one would silently invent a rotation.
  double coplanarity_tolerance{0.01};  // [m]
  /// Warn when two boards are closer together than this. Association is by ID
  /// so it is not unsafe, but it usually means a coordinate was mistyped.
  double proximity_warn{0.10};  // [m]
  /// Warn when the size implied by surveyed corners disagrees with the declared
  /// `marker_size` by more than this fraction.
  double size_mismatch_warn{0.05};  // relative
};

struct TagMapLoadResult
{
  TagMap map;
  /// Non-fatal findings, already formatted for logging. Each names the board it
  /// refers to, because "some board is suspicious" is not actionable.
  std::vector<std::string> warnings;
};

/// Thrown for any condition that makes the map unusable. The message always
/// names the offending tag or field.
class TagMapError : public std::runtime_error
{
public:
  explicit TagMapError(const std::string & what) : std::runtime_error(what) {}
};

/// Result of fitting a tag pose to four surveyed corner points.
struct CornerFit
{
  Eigen::Isometry3d pose{Eigen::Isometry3d::Identity()};
  double marker_size{0.0};
  /// Largest distance from any corner to the fitted plane, metres.
  double planarity_deviation{0.0};
};

/// Recover a tag pose from four surveyed corners, in `Corner` order.
///
/// This is the form a hand survey naturally produces, and it is preferred over
/// writing a quaternion by hand: four measured points fix position, orientation
/// and size at once, with no frame convention for a human to get wrong.
///
/// The rotation is orthonormalized, because measured corners are noisy and the
/// raw axes will not be exactly perpendicular.
CornerFit fitTagFromCorners(const std::array<Eigen::Vector3d, kNumCorners> & corners);

/// The inverse of `fitTagFromCorners`: where a tag's corners land in the map.
/// Used for visualization, and by the round-trip test that pins the two against
/// each other.
std::array<Eigen::Vector3d, kNumCorners> tagCornersInMap(
  const Eigen::Isometry3d & pose, double marker_size);

/// Parse a tag map from YAML text.
TagMapLoadResult loadTagMapFromString(
  const std::string & yaml_text, const TagMapOptions & options = {});

/// Parse a tag map from a file on disk.
TagMapLoadResult loadTagMapFromFile(
  const std::string & path, const TagMapOptions & options = {});

}  // namespace golfcart::aruco_localizer

#endif  // GOLFCART_ARUCO_LOCALIZER__TAG_MAP_HPP_
