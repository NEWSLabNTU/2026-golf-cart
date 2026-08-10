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

#include <golfcart_aruco_localizer/tag_frame.hpp>
#include <golfcart_aruco_localizer/tag_map.hpp>

#include <gtest/gtest.h>

#include <Eigen/Geometry>
#include <opencv2/aruco.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>

#include <vector>

namespace golfcart::aruco_localizer
{
namespace
{

constexpr double kMarkerSize = 0.384;

Eigen::Isometry3d referencePose()
{
  // Deliberately not fronto-parallel: a square seen head-on is the ambiguous
  // case, where IPPE's two solutions are equally good and this test would be
  // measuring a coin flip rather than the corner convention.
  Eigen::Isometry3d pose = Eigen::Isometry3d::Identity();
  pose.linear() = (Eigen::AngleAxisd(0.45, Eigen::Vector3d::UnitY()) *
                   Eigen::AngleAxisd(0.20, Eigen::Vector3d::UnitX()))
                    .toRotationMatrix();
  pose.translation() = Eigen::Vector3d{0.08, -0.05, 1.60};
  return pose;
}

}  // namespace

TEST(TagFrame, MatchesTheDocumentedLiteralLayout)
{
  const auto corners = tagLocalCorners(2.0);
  EXPECT_TRUE(corners[kTopLeft].isApprox(Eigen::Vector3d(-1.0, +1.0, 0.0)));
  EXPECT_TRUE(corners[kTopRight].isApprox(Eigen::Vector3d(+1.0, +1.0, 0.0)));
  EXPECT_TRUE(corners[kBottomRight].isApprox(Eigen::Vector3d(+1.0, -1.0, 0.0)));
  EXPECT_TRUE(corners[kBottomLeft].isApprox(Eigen::Vector3d(-1.0, -1.0, 0.0)));
}

TEST(TagFrame, NormalPointsOutOfThePrintedFace)
{
  const auto c = tagLocalCorners(kMarkerSize);
  const Eigen::Vector3d normal =
    (c[kTopRight] - c[kTopLeft]).cross(c[kTopLeft] - c[kBottomLeft]).normalized();
  EXPECT_TRUE(normal.isApprox(Eigen::Vector3d::UnitZ(), 1e-9));
}

// The test this file exists for.
//
// Our corner array is handed to PnP, so it has to be interchangeable with the
// one OpenCV builds internally. A permutation or a flipped axis would still
// converge and still report a small residual -- it just returns a pose rotated
// by a multiple of 90 degrees, which nothing downstream can detect.
//
// So: place a marker at a known pose, project OUR corners through a pinhole
// camera, and ask OpenCV to recover the pose from those pixels using ITS own
// object points. The two conventions agree if and only if the pose comes back.
TEST(TagFrame, IsInterchangeableWithOpenCvObjectPoints)
{
  const Eigen::Isometry3d expected = referencePose();

  const double fx = 900.0;
  const double fy = 900.0;
  const double cx = 960.0;
  const double cy = 640.0;

  std::vector<cv::Point2f> image_corners;
  for (const auto & local : tagLocalCorners(kMarkerSize)) {
    const Eigen::Vector3d in_camera = expected * local;
    ASSERT_GT(in_camera.z(), 0.0) << "test pose puts a corner behind the camera";
    image_corners.emplace_back(
      static_cast<float>(fx * in_camera.x() / in_camera.z() + cx),
      static_cast<float>(fy * in_camera.y() / in_camera.z() + cy));
  }

  cv::Mat camera_matrix = (cv::Mat_<double>(3, 3) << fx, 0, cx, 0, fy, cy, 0, 0, 1);
  const cv::Mat distortion = cv::Mat::zeros(5, 1, CV_64F);

  const std::vector<std::vector<cv::Point2f>> all_corners{image_corners};
  std::vector<cv::Vec3d> rvecs;
  std::vector<cv::Vec3d> tvecs;
  cv::aruco::estimatePoseSingleMarkers(
    all_corners, static_cast<float>(kMarkerSize), camera_matrix, distortion, rvecs, tvecs);

  ASSERT_EQ(rvecs.size(), 1U);

  cv::Mat rotation_cv;
  cv::Rodrigues(rvecs[0], rotation_cv);

  Eigen::Matrix3d rotation;
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) {
      rotation(r, c) = rotation_cv.at<double>(r, c);
    }
  }
  const Eigen::Vector3d translation{tvecs[0][0], tvecs[0][1], tvecs[0][2]};

  EXPECT_LT((translation - expected.translation()).norm(), 1e-3)
    << "OpenCV recovered a different position -- corner ORDER is probably wrong";

  const Eigen::AngleAxisd residual(rotation.transpose() * expected.linear());
  EXPECT_LT(std::abs(residual.angle()), 1e-3)
    << "OpenCV recovered a pose rotated by " << residual.angle() * 180.0 / M_PI
    << " deg about (" << residual.axis().transpose()
    << ") -- the tag frame convention disagrees with OpenCV's";
}

TEST(TagFrame, MapCornersRoundTripThroughTheFit)
{
  const Eigen::Isometry3d expected = referencePose();
  const auto corners = tagCornersInMap(expected, kMarkerSize);

  const CornerFit fit = fitTagFromCorners(corners);

  EXPECT_NEAR(fit.marker_size, kMarkerSize, 1e-9);
  EXPECT_LT(fit.planarity_deviation, 1e-9);
  EXPECT_LT((fit.pose.translation() - expected.translation()).norm(), 1e-9);

  const Eigen::AngleAxisd residual(fit.pose.linear().transpose() * expected.linear());
  EXPECT_LT(std::abs(residual.angle()), 1e-9);
}

TEST(TagFrame, FitOrthonormalizesNoisyCorners)
{
  const Eigen::Isometry3d expected = referencePose();
  auto corners = tagCornersInMap(expected, kMarkerSize);

  // A few millimetres of survey noise, which is what a hand measurement looks
  // like. The fitted axes must still come back as a true rotation.
  corners[kTopLeft] += Eigen::Vector3d{0.003, -0.002, 0.001};
  corners[kBottomRight] += Eigen::Vector3d{-0.002, 0.003, -0.001};

  const CornerFit fit = fitTagFromCorners(corners);

  const Eigen::Matrix3d & r = fit.pose.linear();
  EXPECT_TRUE((r.transpose() * r).isApprox(Eigen::Matrix3d::Identity(), 1e-9));
  EXPECT_NEAR(r.determinant(), 1.0, 1e-9);

  const Eigen::AngleAxisd residual(r.transpose() * expected.linear());
  EXPECT_LT(std::abs(residual.angle()), 0.05);
}

}  // namespace golfcart::aruco_localizer
