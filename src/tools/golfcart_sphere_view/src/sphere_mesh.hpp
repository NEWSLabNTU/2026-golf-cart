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

#ifndef GOLFCART_SPHERE_VIEW__SPHERE_MESH_HPP_
#define GOLFCART_SPHERE_VIEW__SPHERE_MESH_HPP_

#include <OgreQuaternion.h>
#include <OgreVector3.h>

#include <sensor_msgs/msg/camera_info.hpp>

#include <vector>

#include "textured_patch.hpp"

namespace golfcart_sphere_view
{

/// Where the camera sits relative to the sphere centre, both in base_link.
struct CameraPose
{
  Ogre::Vector3 position;
  Ogre::Quaternion orientation;
};

/// How finely the sphere is tessellated, in degrees per step.
struct SphereResolution
{
  double latitude_step_deg{1.0};
  double longitude_step_deg{1.0};
};

/// Project a pixel-space point through a CameraInfo's distortion model.
///
/// Returns false when the point is behind the camera or the model cannot be
/// evaluated. The distortion coefficients are interpreted in OpenCV's order,
/// k1 k2 p1 p2 [k3 [k4 k5 k6 [s1 s2 s3 s4]]], which is what both plumb_bob and
/// rational_polynomial use; anything longer than the model needs is ignored.
bool projectToPixel(
  const sensor_msgs::msg::CameraInfo & camera_info, const Ogre::Vector3 & point_in_optical_frame,
  double & u, double & v);

/// Build the part of the sphere this camera can see.
///
/// Directions are generated on a latitude/longitude grid in base_link, offset
/// to the camera's optical frame, and projected. A grid cell becomes two
/// triangles when all four of its corners land inside the image; partial cells
/// are dropped rather than clipped, which costs at most one cell of coverage at
/// the edge of the frame and keeps this function short enough to trust.
///
/// The result is in base_link coordinates at the given radius. It depends only
/// on the CameraInfo, the pose and the radius -- not on any image -- so it is
/// rebuilt when the calibration or the transform changes and not per frame.
std::vector<PatchVertex> buildCameraPatch(
  const sensor_msgs::msg::CameraInfo & camera_info, const CameraPose & pose, double radius,
  const SphereResolution & resolution);

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__SPHERE_MESH_HPP_
