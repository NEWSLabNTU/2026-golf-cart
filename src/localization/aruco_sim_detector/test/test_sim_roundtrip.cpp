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

#include <aruco_sim_detector/marker_pnp.hpp>
#include <aruco_sim_detector/sim_camera.hpp>
#include <golfcart_aruco_localizer/tag_frame.hpp>
#include <golfcart_aruco_localizer/tag_map.hpp>

#include <gtest/gtest.h>

#include <Eigen/Geometry>
#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>

#include <limits>
#include <vector>

namespace golfcart::aruco_sim
{
namespace
{

using aruco_localizer::kNumCorners;
using aruco_localizer::tagLocalCorners;

constexpr double kMarkerSize = 0.384;

SimCamera testCamera()
{
  SimCamera cam;
  cam.name = "left";
  cam.optical_frame = "camera_left_optical";
  cam.fx = 900.0;
  cam.fy = 900.0;
  cam.cx = 960.0;
  cam.cy = 640.0;
  cam.width = 1920;
  cam.height = 1280;
  // Looking to the vehicle's left. Optical convention is z forward, x right,
  // y down, so a left-facing camera is a single -90 degree roll about base x:
  // optical z lands on base +y, optical x on base +x, optical y on base -z.
  Eigen::Isometry3d t = Eigen::Isometry3d::Identity();
  t.linear() = Eigen::AngleAxisd(-M_PI_2, Eigen::Vector3d::UnitX()).toRotationMatrix();
  t.translation() = Eigen::Vector3d{0.0, 0.4, 0.6};
  cam.base_to_cam = t;
  return cam;
}

/// Where we want the board to sit relative to the camera, chosen so it is
/// comfortably inside the image and viewed obliquely — about 30 degrees off its
/// normal, clear of both the ambiguity cone and the detection limit.
Eigen::Isometry3d desiredCamToTag()
{
  Eigen::Isometry3d t = Eigen::Isometry3d::Identity();
  t.linear() = (Eigen::AngleAxisd(M_PI, Eigen::Vector3d::UnitY()) *
                Eigen::AngleAxisd(0.5, Eigen::Vector3d::UnitX()))
                 .toRotationMatrix();
  t.translation() = Eigen::Vector3d{0.6, -0.1, 3.5};
  return t;
}

/// Place the board in the map so that it lands at `desiredCamToTag()` for this
/// vehicle pose. Deriving the board pose from the wanted view, rather than
/// hand-picking map coordinates and hoping, keeps the test robust to changes in
/// the camera mounting.
Eigen::Isometry3d boardForView(const SimCamera & cam, const Eigen::Isometry3d & map_to_base)
{
  return map_to_base * cam.base_to_cam * desiredCamToTag();
}

/// Project a board's corners, exactly as the node does.
std::vector<cv::Point2f> projectBoard(
  const SimCamera & cam, const Eigen::Isometry3d & map_to_base,
  const Eigen::Isometry3d & map_to_tag, double marker_size)
{
  const Eigen::Isometry3d cam_to_tag =
    cam.base_to_cam.inverse() * map_to_base.inverse() * map_to_tag;
  std::vector<cv::Point2f> pixels;
  for (const auto & p : tagLocalCorners(marker_size)) {
    const auto uv = project(cam, cam_to_tag * p);
    EXPECT_TRUE(uv.has_value()) << "corner fell outside the image; fix the test geometry";
    if (!uv) {
      return {};
    }
    pixels.emplace_back(static_cast<float>(uv->x()), static_cast<float>(uv->y()));
  }
  return pixels;
}

/// Both candidate poses, via the same helper the node uses.
struct Solutions
{
  std::vector<Eigen::Isometry3d> poses;
  std::vector<double> errors;
};

Solutions solveBoth(
  const SimCamera & cam, const std::vector<cv::Point2f> & pixels, double marker_size)
{
  const MarkerPnpResult r = solveMarkerPose(pixels, marker_size, cam.intrinsics());
  Solutions out;
  if (!r.valid) {
    return out;
  }
  out.poses = {r.pose_1, r.pose_2};
  out.errors = {r.error_1, r.error_2};
  return out;
}

/// Vehicle pose implied by one board observation, the chain the localizer uses:
///   T_map_base = T_map_tag * (T_base_cam * T_cam_tag)^-1
Eigen::Isometry3d vehicleFrom(
  const Eigen::Isometry3d & map_to_tag, const SimCamera & cam,
  const Eigen::Isometry3d & cam_to_tag)
{
  return map_to_tag * (cam.base_to_cam * cam_to_tag).inverse();
}

double positionError(const Eigen::Isometry3d & a, const Eigen::Isometry3d & b)
{
  return (a.translation() - b.translation()).norm();
}

double angleError(const Eigen::Isometry3d & a, const Eigen::Isometry3d & b)
{
  return std::abs(Eigen::AngleAxisd(a.linear().transpose() * b.linear()).angle());
}

}  // namespace

// The test this package exists to make possible.
//
// Synthesise a detection from a known vehicle pose, then invert the chain to
// recover that pose. This covers, in one shot, every error that otherwise
// produces a plausible-but-wrong pose: a corner permutation, a missing
// optical-frame rotation, a transform composed in the wrong direction, or a
// tag-frame convention mismatch between the map and the solver. Each of those
// converges happily on its own and reports a small residual.
//
// It asserts that ONE OF the two IPPE solutions closes exactly, not that the
// first one does. That is not a weakened test — it is the honest one. A single
// square is genuinely two-valued, and with noiseless corners the two solutions
// can fit closely enough that their ordering is numerical luck. Resolving which
// is correct needs agreement across boards, which is the localizer's job, not
// the geometry chain's. `SingleBoardCannotResolveItsOwnFlip` below pins that
// distinction so it cannot be quietly forgotten.
TEST(SimRoundTrip, ZeroNoiseRecoversTheVehiclePose)
{
  const SimCamera cam = testCamera();

  Eigen::Isometry3d map_to_base = Eigen::Isometry3d::Identity();
  map_to_base.linear() =
    Eigen::AngleAxisd(0.3, Eigen::Vector3d::UnitZ()).toRotationMatrix();
  map_to_base.translation() = Eigen::Vector3d{1.0, 0.5, 0.0};
  const Eigen::Isometry3d map_to_tag = boardForView(cam, map_to_base);

  const auto pixels = projectBoard(cam, map_to_base, map_to_tag, kMarkerSize);
  ASSERT_EQ(pixels.size(), kNumCorners);

  const Solutions sols = solveBoth(cam, pixels, kMarkerSize);
  ASSERT_FALSE(sols.poses.empty());

  double best_position = std::numeric_limits<double>::max();
  double best_angle = std::numeric_limits<double>::max();
  for (const auto & cam_to_tag : sols.poses) {
    const Eigen::Isometry3d recovered = vehicleFrom(map_to_tag, cam, cam_to_tag);
    best_position = std::min(best_position, positionError(recovered, map_to_base));
    best_angle = std::min(best_angle, angleError(recovered, map_to_base));
  }

  // Tolerance is 0.1 mm, not machine epsilon: OpenCV takes corners as float, so
  // pixel coordinates near 1000 carry about 1e-4 px of representation error,
  // which lands as a few micrometres of pose error at these ranges. The bugs
  // this test exists to catch — a corner permutation, a missing optical-frame
  // rotation, an inverted transform — are centimetres and degrees, so there is
  // no risk of hiding one behind this margin.
  EXPECT_LT(best_position, 1e-4)
    << "no solution recovered the vehicle position; closest was " << best_position
    << " m. Suspect corner order, the optical frame, or a transform direction.";
  EXPECT_LT(best_angle, 1e-4)
    << "no solution recovered the vehicle orientation; closest was "
    << best_angle * 180.0 / M_PI << " deg.";
}

// The reason the test above says "one of".
//
// A single board cannot tell you which of its two poses is real. At this
// geometry both solutions fit the corners closely, so the reprojection-error
// ratio sits near 1 — which is precisely the detector saying "I do not know".
// The design's answer is consensus across boards with different normals; there
// is no threshold that rescues a lone board.
TEST(SimRoundTrip, SingleBoardCannotResolveItsOwnFlip)
{
  const SimCamera cam = testCamera();
  Eigen::Isometry3d map_to_base = Eigen::Isometry3d::Identity();
  map_to_base.translation() = Eigen::Vector3d{1.0, 0.5, 0.0};
  const Eigen::Isometry3d map_to_tag = boardForView(cam, map_to_base);

  const auto pixels = projectBoard(cam, map_to_base, map_to_tag, kMarkerSize);
  ASSERT_EQ(pixels.size(), kNumCorners);

  const Solutions sols = solveBoth(cam, pixels, kMarkerSize);
  ASSERT_EQ(sols.poses.size(), 2U) << "IPPE_SQUARE should return two solutions";

  // The two candidate vehicle poses genuinely differ — this is a real
  // ambiguity, not a duplicate answer.
  const Eigen::Isometry3d a = vehicleFrom(map_to_tag, cam, sols.poses[0]);
  const Eigen::Isometry3d b = vehicleFrom(map_to_tag, cam, sols.poses[1]);
  EXPECT_GT(angleError(a, b), 0.1)
    << "the two solutions collapsed together; the fixture is not exercising the ambiguity";
}

TEST(SimRoundTrip, NoiseDegradesThePoseInProportion)
{
  const SimCamera cam = testCamera();
  Eigen::Isometry3d map_to_base = Eigen::Isometry3d::Identity();
  map_to_base.translation() = Eigen::Vector3d{1.0, 0.5, 0.0};
  const Eigen::Isometry3d map_to_tag = boardForView(cam, map_to_base);

  auto pixels = projectBoard(cam, map_to_base, map_to_tag, kMarkerSize);
  ASSERT_EQ(pixels.size(), kNumCorners);

  // Half a pixel on every corner. The pose must move, but stay nearby: if a
  // sub-pixel perturbation throws it metres away, the geometry is degenerate
  // and the fixture is wrong rather than the code.
  for (auto & px : pixels) {
    px.x += 0.5f;
  }
  const Solutions sols = solveBoth(cam, pixels, kMarkerSize);
  ASSERT_FALSE(sols.poses.empty());

  double best = std::numeric_limits<double>::max();
  for (const auto & cam_to_tag : sols.poses) {
    best = std::min(best, positionError(vehicleFrom(map_to_tag, cam, cam_to_tag), map_to_base));
  }
  EXPECT_GT(best, 1e-9) << "noise had no effect at all — is it being applied?";
  EXPECT_LT(best, 0.5) << "half a pixel moved the pose " << best << " m";
}

TEST(SimCameraModel, ProjectionRejectsPointsBehindAndOutsideTheImage)
{
  const SimCamera cam = testCamera();
  EXPECT_FALSE(project(cam, Eigen::Vector3d{0.0, 0.0, -1.0}).has_value());
  EXPECT_FALSE(project(cam, Eigen::Vector3d{100.0, 0.0, 1.0}).has_value());
  EXPECT_TRUE(project(cam, Eigen::Vector3d{0.0, 0.0, 3.0}).has_value());
}

TEST(SimCameraModel, IncidenceAngleIsZeroLookingDownTheNormal)
{
  // Board 3 m in front of the camera, its +z (outward normal) pointing back.
  Eigen::Isometry3d cam_to_tag = Eigen::Isometry3d::Identity();
  cam_to_tag.linear() = Eigen::AngleAxisd(M_PI, Eigen::Vector3d::UnitY()).toRotationMatrix();
  cam_to_tag.translation() = Eigen::Vector3d{0.0, 0.0, 3.0};

  const auto phi = incidenceAngle(cam_to_tag);
  ASSERT_TRUE(phi.has_value());
  EXPECT_NEAR(*phi, 0.0, 1e-9);

  // Turn the board away and its face stops being visible.
  Eigen::Isometry3d away = cam_to_tag;
  away.linear() = Eigen::Matrix3d::Identity();
  EXPECT_FALSE(incidenceAngle(away).has_value());
}

}  // namespace golfcart::aruco_sim
