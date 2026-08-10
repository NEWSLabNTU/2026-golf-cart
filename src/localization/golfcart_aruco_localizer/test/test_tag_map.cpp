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

#include <gtest/gtest.h>

#include <Eigen/Geometry>

#include <iomanip>
#include <sstream>
#include <string>

namespace golfcart::aruco_localizer
{
namespace
{

constexpr double kMarkerSize = 0.384;

std::string num(const double v)
{
  std::ostringstream os;
  os << std::setprecision(17) << v;
  return os.str();
}

Eigen::Isometry3d referencePose()
{
  Eigen::Isometry3d pose = Eigen::Isometry3d::Identity();
  pose.linear() = (Eigen::AngleAxisd(0.9, Eigen::Vector3d::UnitZ()) *
                   Eigen::AngleAxisd(0.3, Eigen::Vector3d::UnitX()))
                    .toRotationMatrix();
  pose.translation() = Eigen::Vector3d{12.34, -3.21, 1.5};
  return pose;
}

std::string header()
{
  return
    "frame_id: map\n"
    "survey:\n"
    "  date: \"2026-08-10\"\n"
    "  method: \"laser distance meter\"\n"
    "  stated_accuracy: 0.02\n"
    "defaults:\n"
    "  dictionary: DICT_5X5_1000\n"
    "  marker_size: " + num(kMarkerSize) + "\n"
    "tags:\n";
}

/// The same board written as a quaternion pose.
std::string poseFormEntry(const std::uint32_t id, const Eigen::Isometry3d & pose)
{
  const Eigen::Quaterniond q(pose.linear());
  const Eigen::Vector3d & t = pose.translation();
  return
    "  - id: " + std::to_string(id) + "\n"
    "    position: {x: " + num(t.x()) + ", y: " + num(t.y()) + ", z: " + num(t.z()) + "}\n"
    "    orientation: {x: " + num(q.x()) + ", y: " + num(q.y()) + ", z: " + num(q.z()) +
    ", w: " + num(q.w()) + "}\n";
}

/// The same board written as four surveyed corners.
std::string cornerFormEntry(
  const std::uint32_t id, const Eigen::Isometry3d & pose, const double size = kMarkerSize)
{
  const auto corners = tagCornersInMap(pose, size);
  std::string out = "  - id: " + std::to_string(id) + "\n    corners:\n";
  for (const auto & c : corners) {
    out += "      - [" + num(c.x()) + ", " + num(c.y()) + ", " + num(c.z()) + "]\n";
  }
  return out;
}

}  // namespace

// The load-bearing test of this file.
//
// A hand survey produces corners; the bootstrap and most examples produce a
// pose. Both have to mean the same thing, and the failure mode when they do not
// is a board silently rotated by a multiple of 90 degrees -- which the solve
// will happily converge around.
TEST(TagMap, CornerFormAndPoseFormAgree)
{
  const Eigen::Isometry3d expected = referencePose();

  const auto by_pose = loadTagMapFromString(header() + poseFormEntry(696, expected));
  const auto by_corners = loadTagMapFromString(header() + cornerFormEntry(696, expected));

  ASSERT_EQ(by_pose.map.tags.size(), 1U);
  ASSERT_EQ(by_corners.map.tags.size(), 1U);

  const TagPose & a = by_pose.map.tags.at(696);
  const TagPose & b = by_corners.map.tags.at(696);

  EXPECT_LT((a.pose.translation() - b.pose.translation()).norm(), 1e-9);
  EXPECT_LT((a.pose.translation() - expected.translation()).norm(), 1e-9);

  const Eigen::AngleAxisd between(a.pose.linear().transpose() * b.pose.linear());
  EXPECT_LT(std::abs(between.angle()), 1e-9)
    << "corner form and pose form disagree by " << between.angle() * 180.0 / M_PI << " deg";

  const Eigen::AngleAxisd from_expected(b.pose.linear().transpose() * expected.linear());
  EXPECT_LT(std::abs(from_expected.angle()), 1e-9);

  EXPECT_NEAR(a.marker_size, kMarkerSize, 1e-9);
  EXPECT_NEAR(b.marker_size, kMarkerSize, 1e-9);
}

TEST(TagMap, InheritsSizeAndUncertaintyFromDefaults)
{
  const auto loaded = loadTagMapFromString(header() + poseFormEntry(1, referencePose()));
  const TagPose & tag = loaded.map.tags.at(1);
  EXPECT_NEAR(tag.marker_size, kMarkerSize, 1e-12);
  EXPECT_NEAR(tag.position_stddev, 0.02, 1e-12);
  EXPECT_EQ(loaded.map.dictionary, "DICT_5X5_1000");
  EXPECT_EQ(loaded.map.frame_id, "map");
  EXPECT_EQ(loaded.map.survey.method, "laser distance meter");
}

TEST(TagMap, PerTagOverridesWin)
{
  const std::string yaml = header() + poseFormEntry(1, referencePose()) +
                           "    marker_size: 0.2\n    position_stddev: 0.005\n";
  const auto loaded = loadTagMapFromString(yaml);
  EXPECT_NEAR(loaded.map.tags.at(1).marker_size, 0.2, 1e-12);
  EXPECT_NEAR(loaded.map.tags.at(1).position_stddev, 0.005, 1e-12);
}

TEST(TagMap, DuplicateIdIsRejectedAndNamed)
{
  const Eigen::Isometry3d pose = referencePose();
  Eigen::Isometry3d other = pose;
  other.translation() += Eigen::Vector3d{5.0, 0.0, 0.0};

  const std::string yaml = header() + poseFormEntry(696, pose) + poseFormEntry(696, other);

  try {
    loadTagMapFromString(yaml);
    FAIL() << "duplicate ID must be rejected -- unique IDs are what make "
              "association prior-free";
  } catch (const TagMapError & e) {
    EXPECT_NE(std::string(e.what()).find("696"), std::string::npos)
      << "the error must name the offending ID, got: " << e.what();
  }
}

TEST(TagMap, NonPlanarCornersAreRejectedAndNamed)
{
  const auto corners = tagCornersInMap(referencePose(), kMarkerSize);
  std::string yaml = header() + "  - id: 42\n    corners:\n";
  for (std::size_t i = 0; i < kNumCorners; ++i) {
    // Push one corner well off the plane -- 5 cm, far past the 1 cm tolerance.
    const Eigen::Vector3d c =
      corners[i] + (i == kBottomRight ? Eigen::Vector3d{0.0, 0.0, 0.05} : Eigen::Vector3d::Zero());
    yaml += "      - [" + num(c.x()) + ", " + num(c.y()) + ", " + num(c.z()) + "]\n";
  }

  try {
    loadTagMapFromString(yaml);
    FAIL() << "non-planar corners must be rejected -- a non-planar quad has no "
              "well-defined orientation";
  } catch (const TagMapError & e) {
    const std::string what = e.what();
    EXPECT_NE(what.find("42"), std::string::npos) << what;
    EXPECT_NE(what.find("coplanar"), std::string::npos) << what;
  }
}

TEST(TagMap, MalformedQuaternionIsRejectedRatherThanNormalized)
{
  const std::string yaml = header() +
    "  - id: 7\n"
    "    position: {x: 0.0, y: 0.0, z: 1.0}\n"
    "    orientation: {x: 0.0, y: 0.0, z: 0.0, w: 0.5}\n";

  EXPECT_THROW(loadTagMapFromString(yaml), TagMapError);
}

TEST(TagMap, BothFormsTogetherIsRejected)
{
  const std::string yaml =
    header() + poseFormEntry(3, referencePose()) +
    "    corners: [[0,0,0],[1,0,0],[1,1,0],[0,1,0]]\n";
  EXPECT_THROW(loadTagMapFromString(yaml), TagMapError);
}

TEST(TagMap, NeitherFormIsRejected)
{
  const std::string yaml = header() + "  - id: 3\n";
  EXPECT_THROW(loadTagMapFromString(yaml), TagMapError);
}

TEST(TagMap, MissingUncertaintyIsRejected)
{
  // No survey block and no per-tag stddev: the board has no weight, and
  // assuming one would quietly invent confidence.
  const std::string yaml =
    "frame_id: map\n"
    "defaults:\n  marker_size: " + num(kMarkerSize) + "\n"
    "tags:\n" + poseFormEntry(1, referencePose());
  EXPECT_THROW(loadTagMapFromString(yaml), TagMapError);
}

TEST(TagMap, MissingMarkerSizeIsRejected)
{
  const std::string yaml =
    "frame_id: map\n"
    "survey:\n  stated_accuracy: 0.02\n"
    "tags:\n" + poseFormEntry(1, referencePose());
  EXPECT_THROW(loadTagMapFromString(yaml), TagMapError);
}

TEST(TagMap, EmptyOrMissingTagsIsRejected)
{
  EXPECT_THROW(loadTagMapFromString("frame_id: map\ntags: []\n"), TagMapError);
  EXPECT_THROW(loadTagMapFromString("frame_id: map\n"), TagMapError);
  EXPECT_THROW(loadTagMapFromString("tags:\n  - id: 1\n"), TagMapError);
}

TEST(TagMap, WarnsAboutCoincidentBoards)
{
  Eigen::Isometry3d a = referencePose();
  Eigen::Isometry3d b = a;
  b.translation() += Eigen::Vector3d{0.01, 0.0, 0.0};

  const auto loaded = loadTagMapFromString(header() + poseFormEntry(1, a) + poseFormEntry(2, b));

  ASSERT_FALSE(loaded.warnings.empty());
  const std::string & w = loaded.warnings.front();
  EXPECT_NE(w.find("1"), std::string::npos) << w;
  EXPECT_NE(w.find("2"), std::string::npos) << w;
}

TEST(TagMap, WarnsWhenDeclaredSizeDisagreesWithSurveyedCorners)
{
  // Corners describe a 0.384 m marker; the entry claims 0.5 m.
  const std::string yaml =
    header() + cornerFormEntry(9, referencePose()) + "    marker_size: 0.5\n";

  const auto loaded = loadTagMapFromString(yaml);

  ASSERT_FALSE(loaded.warnings.empty());
  EXPECT_NE(loaded.warnings.front().find("9"), std::string::npos)
    << loaded.warnings.front();
  // The declared value wins -- the warning exists so a human can arbitrate.
  EXPECT_NEAR(loaded.map.tags.at(9).marker_size, 0.5, 1e-12);
}

TEST(TagMap, AcceptsBothPointSpellings)
{
  const std::string mapping_form = header() +
    "  - id: 1\n"
    "    position: {x: 1.0, y: 2.0, z: 3.0}\n"
    "    orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}\n";
  const std::string sequence_form = header() +
    "  - id: 1\n"
    "    position: [1.0, 2.0, 3.0]\n"
    "    orientation: {x: 0.0, y: 0.0, z: 0.0, w: 1.0}\n";

  const auto a = loadTagMapFromString(mapping_form);
  const auto b = loadTagMapFromString(sequence_form);
  EXPECT_LT(
    (a.map.tags.at(1).pose.translation() - b.map.tags.at(1).pose.translation()).norm(), 1e-12);
}

TEST(TagMap, RejectsGarbageYaml)
{
  EXPECT_THROW(loadTagMapFromString("[ this is not a mapping ]"), TagMapError);
  EXPECT_THROW(loadTagMapFromString("frame_id: map\ntags: 3\n"), TagMapError);
}

}  // namespace golfcart::aruco_localizer
