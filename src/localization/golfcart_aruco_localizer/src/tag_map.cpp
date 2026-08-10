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

#include <golfcart_aruco_localizer/tag_map.hpp>

#include <Eigen/SVD>
#include <yaml-cpp/yaml.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

namespace
{

/// Quaternions are rejected rather than silently normalized past this. A norm
/// meaningfully off 1 usually means transcription error, not rounding, and
/// normalizing it would bake the mistake in as a plausible rotation.
constexpr double kQuaternionNormTolerance = 1e-3;

std::string fmt(const double v)
{
  std::ostringstream os;
  os.precision(4);
  os << std::fixed << v;
  return os.str();
}

[[noreturn]] void fail(const std::string & message)
{
  throw TagMapError(message);
}

const YAML::Node require(const YAML::Node & parent, const std::string & key, const std::string & ctx)
{
  if (!parent[key]) {
    fail(ctx + ": missing required field '" + key + "'");
  }
  return parent[key];
}

Eigen::Vector3d parseXyz(const YAML::Node & node, const std::string & ctx)
{
  if (node.IsSequence()) {
    if (node.size() != 3) {
      fail(ctx + ": expected 3 values, got " + std::to_string(node.size()));
    }
    return {node[0].as<double>(), node[1].as<double>(), node[2].as<double>()};
  }
  return {
    require(node, "x", ctx).as<double>(), require(node, "y", ctx).as<double>(),
    require(node, "z", ctx).as<double>()};
}

}  // namespace

CornerFit fitTagFromCorners(const std::array<Eigen::Vector3d, kNumCorners> & corners)
{
  CornerFit fit;

  const Eigen::Vector3d centre =
    0.25 * (corners[kTopLeft] + corners[kTopRight] + corners[kBottomRight] + corners[kBottomLeft]);

  // Axes from opposite edge midpoints rather than a single edge: averaging both
  // edges halves the effect of any one mismeasured corner.
  const Eigen::Vector3d x_raw = 0.5 * ((corners[kTopRight] + corners[kBottomRight]) -
                                       (corners[kTopLeft] + corners[kBottomLeft]));
  const Eigen::Vector3d y_raw = 0.5 * ((corners[kTopLeft] + corners[kTopRight]) -
                                       (corners[kBottomLeft] + corners[kBottomRight]));

  if (x_raw.norm() < 1e-9 || y_raw.norm() < 1e-9) {
    fail("degenerate corner set: the four points are collinear or coincident");
  }

  Eigen::Matrix3d raw;
  raw.col(0) = x_raw.normalized();
  raw.col(1) = y_raw.normalized();
  raw.col(2) = raw.col(0).cross(raw.col(1)).normalized();

  // Measured corners are noisy, so the raw axes are not exactly perpendicular.
  // Project onto SO(3) -- the nearest true rotation in the Frobenius sense.
  Eigen::JacobiSVD<Eigen::Matrix3d> svd(raw, Eigen::ComputeFullU | Eigen::ComputeFullV);
  Eigen::Matrix3d rotation = svd.matrixU() * svd.matrixV().transpose();
  if (rotation.determinant() < 0.0) {
    Eigen::Matrix3d flip = Eigen::Matrix3d::Identity();
    flip(2, 2) = -1.0;
    rotation = svd.matrixU() * flip * svd.matrixV().transpose();
  }

  fit.pose = Eigen::Isometry3d::Identity();
  fit.pose.linear() = rotation;
  fit.pose.translation() = centre;

  // Mean of the four edges rather than of the two axes: an edge length is a
  // direct measurement, whereas an axis is already an average.
  const double edges = (corners[kTopRight] - corners[kTopLeft]).norm() +
                       (corners[kBottomRight] - corners[kTopRight]).norm() +
                       (corners[kBottomLeft] - corners[kBottomRight]).norm() +
                       (corners[kTopLeft] - corners[kBottomLeft]).norm();
  fit.marker_size = 0.25 * edges;

  // Planarity against the best-fit plane, whose normal is the least-explained
  // direction of the centred points.
  Eigen::Matrix<double, kNumCorners, 3> centred;
  for (std::size_t i = 0; i < kNumCorners; ++i) {
    centred.row(static_cast<Eigen::Index>(i)) = (corners[i] - centre).transpose();
  }
  Eigen::JacobiSVD<Eigen::Matrix<double, kNumCorners, 3>> plane_svd(centred, Eigen::ComputeFullV);
  const Eigen::Vector3d normal = plane_svd.matrixV().col(2);

  fit.planarity_deviation = 0.0;
  for (const auto & corner : corners) {
    fit.planarity_deviation =
      std::max(fit.planarity_deviation, std::abs((corner - centre).dot(normal)));
  }

  return fit;
}

std::array<Eigen::Vector3d, kNumCorners> tagCornersInMap(
  const Eigen::Isometry3d & pose, const double marker_size)
{
  const auto local = tagLocalCorners(marker_size);
  std::array<Eigen::Vector3d, kNumCorners> out;
  for (std::size_t i = 0; i < kNumCorners; ++i) {
    out[i] = pose * local[i];
  }
  return out;
}

TagMapLoadResult loadTagMapFromString(
  const std::string & yaml_text, const TagMapOptions & options)
{
  TagMapLoadResult result;

  YAML::Node root;
  try {
    root = YAML::Load(yaml_text);
  } catch (const YAML::Exception & e) {
    fail(std::string("tag map is not valid YAML: ") + e.what());
  }
  if (!root || !root.IsMap()) {
    fail("tag map root must be a mapping");
  }

  result.map.frame_id = require(root, "frame_id", "tag map").as<std::string>();

  if (root["survey"]) {
    const auto & survey = root["survey"];
    result.map.survey.date = survey["date"] ? survey["date"].as<std::string>() : std::string{};
    result.map.survey.method = survey["method"] ? survey["method"].as<std::string>() : std::string{};
    if (survey["stated_accuracy"]) {
      result.map.survey.stated_accuracy = survey["stated_accuracy"].as<double>();
      if (result.map.survey.stated_accuracy <= 0.0) {
        fail("survey.stated_accuracy must be positive");
      }
    }
  }

  double default_marker_size = 0.0;
  if (root["defaults"]) {
    const auto & defaults = root["defaults"];
    if (defaults["dictionary"]) {
      result.map.dictionary = defaults["dictionary"].as<std::string>();
    }
    if (defaults["marker_size"]) {
      default_marker_size = defaults["marker_size"].as<double>();
      if (default_marker_size <= 0.0) {
        fail("defaults.marker_size must be positive");
      }
    }
  }

  const auto & tags = require(root, "tags", "tag map");
  if (!tags.IsSequence()) {
    fail("tag map: 'tags' must be a sequence");
  }
  if (tags.size() == 0) {
    fail("tag map: 'tags' is empty");
  }

  for (std::size_t index = 0; index < tags.size(); ++index) {
    const auto & node = tags[index];
    const std::string where = "tag map entry " + std::to_string(index);

    const auto id_raw = require(node, "id", where).as<std::int64_t>();
    if (id_raw < 0 || id_raw > std::numeric_limits<std::uint32_t>::max()) {
      fail(where + ": id " + std::to_string(id_raw) + " is out of range");
    }
    const auto id = static_cast<std::uint32_t>(id_raw);
    const std::string ctx = "tag " + std::to_string(id);

    // Uniqueness is load-bearing, not hygiene. The whole architecture rests on
    // an ID identifying exactly one physical board: that is what makes
    // association prior-free and cold start possible.
    if (result.map.tags.count(id) != 0) {
      fail(ctx + ": duplicate id (each board must have a unique ID)");
    }

    const bool has_corners = static_cast<bool>(node["corners"]);
    const bool has_position = static_cast<bool>(node["position"]);
    const bool has_orientation = static_cast<bool>(node["orientation"]);

    if (has_corners && (has_position || has_orientation)) {
      fail(ctx + ": give either 'corners' or 'position'+'orientation', not both");
    }
    if (!has_corners && !(has_position && has_orientation)) {
      fail(ctx + ": needs either 'corners' or both 'position' and 'orientation'");
    }

    TagPose tag;
    tag.id = id;
    double corner_derived_size = 0.0;

    if (has_corners) {
      const auto & corners_node = node["corners"];
      if (!corners_node.IsSequence() || corners_node.size() != kNumCorners) {
        fail(ctx + ": 'corners' must be a sequence of exactly 4 points");
      }
      std::array<Eigen::Vector3d, kNumCorners> corners;
      for (std::size_t c = 0; c < kNumCorners; ++c) {
        corners[c] = parseXyz(corners_node[c], ctx + " corner " + std::to_string(c));
      }

      const CornerFit fit = fitTagFromCorners(corners);
      if (fit.planarity_deviation > options.coplanarity_tolerance) {
        fail(
          ctx + ": surveyed corners are not coplanar -- worst deviation " +
          fmt(fit.planarity_deviation) + " m exceeds tolerance " +
          fmt(options.coplanarity_tolerance) +
          " m. A non-planar quad has no well-defined orientation.");
      }
      tag.pose = fit.pose;
      corner_derived_size = fit.marker_size;
      tag.marker_size = fit.marker_size;
    } else {
      const Eigen::Vector3d position = parseXyz(node["position"], ctx + " position");
      const auto & q_node = node["orientation"];
      const Eigen::Quaterniond q{
        require(q_node, "w", ctx + " orientation").as<double>(),
        require(q_node, "x", ctx + " orientation").as<double>(),
        require(q_node, "y", ctx + " orientation").as<double>(),
        require(q_node, "z", ctx + " orientation").as<double>()};

      if (std::abs(q.norm() - 1.0) > kQuaternionNormTolerance) {
        fail(
          ctx + ": orientation quaternion has norm " + fmt(q.norm()) +
          ", expected 1. Refusing to normalize -- this is usually a transcription "
          "error rather than rounding.");
      }
      tag.pose = Eigen::Isometry3d::Identity();
      tag.pose.linear() = q.normalized().toRotationMatrix();
      tag.pose.translation() = position;
    }

    // Explicit per-tag size wins, then the corner-derived one, then the default.
    if (node["marker_size"]) {
      const auto declared = node["marker_size"].as<double>();
      if (declared <= 0.0) {
        fail(ctx + ": marker_size must be positive");
      }
      if (corner_derived_size > 0.0) {
        const double relative =
          std::abs(declared - corner_derived_size) / std::max(declared, 1e-9);
        if (relative > options.size_mismatch_warn) {
          result.warnings.push_back(
            ctx + ": declared marker_size " + fmt(declared) +
            " m disagrees with the size implied by the surveyed corners (" +
            fmt(corner_derived_size) + " m). Using the declared value.");
        }
      }
      tag.marker_size = declared;
    } else if (tag.marker_size <= 0.0) {
      tag.marker_size = default_marker_size;
    }

    if (tag.marker_size <= 0.0) {
      fail(
        ctx + ": no marker_size -- set it on the tag, or set defaults.marker_size, "
              "or supply corners");
    }

    if (node["position_stddev"]) {
      tag.position_stddev = node["position_stddev"].as<double>();
      if (tag.position_stddev <= 0.0) {
        fail(ctx + ": position_stddev must be positive");
      }
    } else {
      tag.position_stddev = result.map.survey.stated_accuracy;
    }
    if (tag.position_stddev <= 0.0) {
      fail(
        ctx + ": no position uncertainty -- set position_stddev on the tag, or "
              "survey.stated_accuracy for the whole map. This value is the board's "
              "weight in the solve, so it cannot be assumed.");
    }

    result.map.tags.emplace(id, tag);
  }

  // Boards sitting on top of each other are safe -- association is by ID -- but
  // it is nearly always a mistyped coordinate, so say so.
  for (auto a = result.map.tags.begin(); a != result.map.tags.end(); ++a) {
    for (auto b = std::next(a); b != result.map.tags.end(); ++b) {
      const double distance =
        (a->second.pose.translation() - b->second.pose.translation()).norm();
      if (distance < options.proximity_warn) {
        result.warnings.push_back(
          "tags " + std::to_string(a->first) + " and " + std::to_string(b->first) +
          " are only " + fmt(distance) + " m apart -- check for a mistyped coordinate");
      }
    }
  }

  return result;
}

TagMapLoadResult loadTagMapFromFile(const std::string & path, const TagMapOptions & options)
{
  YAML::Node root;
  try {
    root = YAML::LoadFile(path);
  } catch (const YAML::BadFile &) {
    fail("cannot open tag map file: " + path);
  } catch (const YAML::Exception & e) {
    fail("tag map " + path + " is not valid YAML: " + e.what());
  }

  std::ostringstream text;
  text << root;
  try {
    return loadTagMapFromString(text.str(), options);
  } catch (const TagMapError & e) {
    throw TagMapError(path + ": " + e.what());
  }
}

}  // namespace golfcart::aruco_localizer
