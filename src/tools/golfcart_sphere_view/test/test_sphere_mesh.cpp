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

#include <gtest/gtest.h>

#include <OgreMatrix3.h>

#include "sphere_mesh.hpp"

namespace
{

using golfcart_sphere_view::CameraPose;
using golfcart_sphere_view::SphereResolution;
using golfcart_sphere_view::buildCameraPatch;
using golfcart_sphere_view::projectToPixel;

/// A pinhole camera with no distortion: 640x480, 90 degrees across.
sensor_msgs::msg::CameraInfo pinhole()
{
  sensor_msgs::msg::CameraInfo info;
  info.width = 640;
  info.height = 480;
  info.header.frame_id = "camera_optical";
  info.k = {320.0, 0.0, 320.0, 0.0, 320.0, 240.0, 0.0, 0.0, 1.0};
  info.d = {0.0, 0.0, 0.0, 0.0, 0.0};
  return info;
}

/// Rotation taking base_link (x forward, y left, z up) to the optical
/// convention (z forward, x right, y down), which is what a forward-facing
/// camera carries.
Ogre::Quaternion forwardFacingOptical()
{
  Ogre::Matrix3 basis;
  //            optical x      optical y      optical z
  basis.FromAxes(
    Ogre::Vector3(0, -1, 0),  // right is -y in base_link
    Ogre::Vector3(0, 0, -1),  // down is -z
    Ogre::Vector3(1, 0, 0));  // forward is +x
  return Ogre::Quaternion(basis);
}

TEST(ProjectToPixel, CentreRayLandsOnPrincipalPoint)
{
  double u = 0.0;
  double v = 0.0;
  ASSERT_TRUE(projectToPixel(pinhole(), Ogre::Vector3(0, 0, 1), u, v));
  EXPECT_DOUBLE_EQ(u, 320.0);
  EXPECT_DOUBLE_EQ(v, 240.0);
}

TEST(ProjectToPixel, PointsBehindTheCameraAreRejected)
{
  double u = 0.0;
  double v = 0.0;
  EXPECT_FALSE(projectToPixel(pinhole(), Ogre::Vector3(0, 0, -1), u, v));
  EXPECT_FALSE(projectToPixel(pinhole(), Ogre::Vector3(0, 0, 0), u, v));
}

TEST(ProjectToPixel, OffAxisRayScalesWithFocalLength)
{
  double u = 0.0;
  double v = 0.0;
  // x/z = 0.25, so 0.25 * fx = 80 px right of centre.
  ASSERT_TRUE(projectToPixel(pinhole(), Ogre::Vector3(0.25f, 0.0f, 1.0f), u, v));
  EXPECT_DOUBLE_EQ(u, 400.0);
  EXPECT_DOUBLE_EQ(v, 240.0);
}

TEST(ProjectToPixel, RadialDistortionPushesPointsOutward)
{
  auto info = pinhole();
  info.d = {0.1, 0.0, 0.0, 0.0, 0.0};  // positive k1, barrel

  double undistorted_u = 0.0;
  double undistorted_v = 0.0;
  ASSERT_TRUE(projectToPixel(pinhole(), Ogre::Vector3(0.25f, 0.0f, 1.0f), undistorted_u,
    undistorted_v));

  double u = 0.0;
  double v = 0.0;
  ASSERT_TRUE(projectToPixel(info, Ogre::Vector3(0.25f, 0.0f, 1.0f), u, v));
  EXPECT_GT(u, undistorted_u);
  EXPECT_DOUBLE_EQ(v, undistorted_v);
}

TEST(ProjectToPixel, RationalTermsAreReadFromTheirOwnSlots)
{
  // k4 sits in slot 5 and divides, so it must pull the point back toward the
  // centre rather than push it out like k1. This is the ordering the camera
  // files disagree with, and the reason the check is here.
  auto info = pinhole();
  info.d = {0.0, 0.0, 0.0, 0.0, 0.0, 0.1, 0.0, 0.0};

  double u = 0.0;
  double v = 0.0;
  ASSERT_TRUE(projectToPixel(info, Ogre::Vector3(0.25f, 0.0f, 1.0f), u, v));
  EXPECT_LT(u, 400.0);
}

TEST(BuildCameraPatch, ForwardCameraCoversPartOfTheSphere)
{
  CameraPose pose;
  pose.position = Ogre::Vector3::ZERO;
  pose.orientation = forwardFacingOptical();

  const auto triangles = buildCameraPatch(pinhole(), pose, 10.0, SphereResolution{2.0, 2.0});
  ASSERT_FALSE(triangles.empty());
  EXPECT_EQ(triangles.size() % 3, 0u);

  for (const auto & vertex : triangles) {
    EXPECT_GE(vertex.u, 0.0f);
    EXPECT_LE(vertex.u, 1.0f);
    EXPECT_GE(vertex.v, 0.0f);
    EXPECT_LE(vertex.v, 1.0f);
    // Every vertex sits on the sphere it was asked for.
    EXPECT_NEAR(vertex.position.length(), 10.0f, 1e-3f);
    // A camera looking along +x cannot see anything behind the vehicle.
    EXPECT_GT(vertex.position.x, 0.0f);
  }
}

TEST(BuildCameraPatch, EmptyWithoutIntrinsics)
{
  CameraPose pose;
  pose.position = Ogre::Vector3::ZERO;
  pose.orientation = forwardFacingOptical();

  sensor_msgs::msg::CameraInfo info;  // width and height still zero
  EXPECT_TRUE(buildCameraPatch(info, pose, 10.0, SphereResolution{2.0, 2.0}).empty());
  EXPECT_TRUE(buildCameraPatch(pinhole(), pose, 0.0, SphereResolution{2.0, 2.0}).empty());
}

TEST(BuildCameraPatch, OffsetCameraShiftsWhichDirectionsAreCovered)
{
  // Two cameras with the same orientation, one displaced sideways, disagree
  // about which sphere directions they see. That disagreement is the parallax
  // the radius property trades off, so it must be real rather than rounded away.
  CameraPose centred;
  centred.position = Ogre::Vector3::ZERO;
  centred.orientation = forwardFacingOptical();

  CameraPose offset;
  offset.position = Ogre::Vector3(0.0f, 2.0f, 0.0f);
  offset.orientation = forwardFacingOptical();

  const auto a = buildCameraPatch(pinhole(), centred, 10.0, SphereResolution{2.0, 2.0});
  const auto b = buildCameraPatch(pinhole(), offset, 10.0, SphereResolution{2.0, 2.0});
  ASSERT_FALSE(a.empty());
  ASSERT_FALSE(b.empty());

  float a_mean_y = 0.0f;
  for (const auto & vertex : a) {
    a_mean_y += vertex.position.y;
  }
  float b_mean_y = 0.0f;
  for (const auto & vertex : b) {
    b_mean_y += vertex.position.y;
  }
  a_mean_y /= static_cast<float>(a.size());
  b_mean_y /= static_cast<float>(b.size());
  EXPECT_GT(b_mean_y, a_mean_y);
}

}  // namespace
