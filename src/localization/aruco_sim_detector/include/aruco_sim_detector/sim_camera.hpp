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

#ifndef ARUCO_SIM_DETECTOR__SIM_CAMERA_HPP_
#define ARUCO_SIM_DETECTOR__SIM_CAMERA_HPP_

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <array>
#include <optional>
#include <string>

namespace golfcart::aruco_sim
{

/// A simulated pinhole camera.
///
/// No distortion: the real detector hands the localizer corners that have
/// already been mapped into the rectified frame, so the synthetic path must
/// produce the same thing. Adding distortion here and not undistorting would
/// simulate a bug rather than a camera.
struct SimCamera
{
  std::string name;
  std::string optical_frame;
  /// Camera optical frame expressed in base_link. z forward, x right, y down.
  Eigen::Isometry3d base_to_cam{Eigen::Isometry3d::Identity()};
  double fx{0.0};
  double fy{0.0};
  double cx{0.0};
  double cy{0.0};
  int width{0};
  int height{0};
  /// Capture offset from the window reference stamp, seconds. The real cameras
  /// are not hardware-synchronized, and a fixture that pretends they are would
  /// hide the motion-compensation bug it exists to catch.
  double stamp_offset{0.0};

  Eigen::Matrix3d intrinsics() const
  {
    Eigen::Matrix3d k = Eigen::Matrix3d::Identity();
    k(0, 0) = fx;
    k(1, 1) = fy;
    k(0, 2) = cx;
    k(1, 2) = cy;
    return k;
  }
};

/// Project a point already in the camera optical frame.
/// Returns nothing if the point is behind the camera or lands outside the image.
inline std::optional<Eigen::Vector2d> project(
  const SimCamera & cam, const Eigen::Vector3d & p_cam)
{
  if (p_cam.z() <= 1e-6) {
    return std::nullopt;
  }
  const Eigen::Vector2d uv{
    cam.fx * p_cam.x() / p_cam.z() + cam.cx,
    cam.fy * p_cam.y() / p_cam.z() + cam.cy};
  if (uv.x() < 0.0 || uv.x() > static_cast<double>(cam.width) ||
      uv.y() < 0.0 || uv.y() > static_cast<double>(cam.height))
  {
    return std::nullopt;
  }
  return uv;
}

/// Angle between a board's outward normal and the line of sight back to the
/// camera, in radians. Zero means the camera is looking straight down the
/// board's normal.
///
/// Returns nothing when the camera is behind the board — its printed face is
/// not visible, so there is nothing to detect.
///
/// This angle is the one the design calls phi. It bounds the usable window at
/// *both* ends: too small and the planar pose ambiguity dominates, too large
/// and detection fails outright. The simulator only enforces the detection
/// limit; it deliberately still emits ambiguous detections near zero, because
/// resolving those is what the localizer exists to do.
inline std::optional<double> incidenceAngle(const Eigen::Isometry3d & cam_to_tag)
{
  const Eigen::Vector3d normal_in_cam = cam_to_tag.linear().col(2);
  const Eigen::Vector3d line_of_sight = cam_to_tag.translation().normalized();
  const double cos_phi = -normal_in_cam.dot(line_of_sight);
  if (cos_phi <= 0.0) {
    return std::nullopt;
  }
  return std::acos(std::min(1.0, cos_phi));
}

}  // namespace golfcart::aruco_sim

#endif  // ARUCO_SIM_DETECTOR__SIM_CAMERA_HPP_
