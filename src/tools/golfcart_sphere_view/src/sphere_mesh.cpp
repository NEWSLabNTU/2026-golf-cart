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

#include "sphere_mesh.hpp"

#include <cmath>
#include <vector>

namespace golfcart_sphere_view
{
namespace
{

double coefficient(const std::vector<double> & d, std::size_t index)
{
  return index < d.size() ? d[index] : 0.0;
}

}  // namespace

bool projectToPixel(
  const sensor_msgs::msg::CameraInfo & camera_info, const Ogre::Vector3 & point,
  double & u, double & v)
{
  // Optical frame convention, REP-103: z forward, x right, y down. A point at
  // or behind the image plane has no projection.
  if (point.z <= 1e-6) {
    return false;
  }
  const double x = static_cast<double>(point.x) / static_cast<double>(point.z);
  const double y = static_cast<double>(point.y) / static_cast<double>(point.z);

  const auto & d = camera_info.d;
  const double k1 = coefficient(d, 0);
  const double k2 = coefficient(d, 1);
  const double p1 = coefficient(d, 2);
  const double p2 = coefficient(d, 3);
  const double k3 = coefficient(d, 4);
  const double k4 = coefficient(d, 5);
  const double k5 = coefficient(d, 6);
  const double k6 = coefficient(d, 7);
  const double s1 = coefficient(d, 8);
  const double s2 = coefficient(d, 9);
  const double s3 = coefficient(d, 10);
  const double s4 = coefficient(d, 11);

  const double r2 = x * x + y * y;
  const double r4 = r2 * r2;
  const double r6 = r4 * r2;

  const double numerator = 1.0 + k1 * r2 + k2 * r4 + k3 * r6;
  const double denominator = 1.0 + k4 * r2 + k5 * r4 + k6 * r6;
  if (std::abs(denominator) < 1e-12) {
    return false;
  }
  const double radial = numerator / denominator;

  const double x_distorted =
    x * radial + 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x) + s1 * r2 + s2 * r4;
  const double y_distorted =
    y * radial + p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y + s3 * r2 + s4 * r4;

  // K, not P. P describes the rectified image; the topic this display draws is
  // the distorted one straight off the camera, so the distortion applied above
  // has to be paired with the unrectified intrinsics.
  const double fx = camera_info.k[0];
  const double skew = camera_info.k[1];
  const double cx = camera_info.k[2];
  const double fy = camera_info.k[4];
  const double cy = camera_info.k[5];
  if (fx == 0.0 || fy == 0.0) {
    return false;
  }

  u = fx * x_distorted + skew * y_distorted + cx;
  v = fy * y_distorted + cy;
  return true;
}

std::vector<PatchVertex> buildCameraPatch(
  const sensor_msgs::msg::CameraInfo & camera_info, const CameraPose & pose, double radius,
  const SphereResolution & resolution)
{
  std::vector<PatchVertex> triangles;
  if (camera_info.width == 0 || camera_info.height == 0 || radius <= 0.0) {
    return triangles;
  }

  const double width = static_cast<double>(camera_info.width);
  const double height = static_cast<double>(camera_info.height);
  const auto latitude_step = resolution.latitude_step_deg * M_PI / 180.0;
  const auto longitude_step = resolution.longitude_step_deg * M_PI / 180.0;
  const int latitude_count = static_cast<int>(std::round(M_PI / latitude_step));
  const int longitude_count = static_cast<int>(std::round(2.0 * M_PI / longitude_step));

  const Ogre::Quaternion optical_from_base = pose.orientation.Inverse();

  // A grid corner that projects inside the image, expressed both ways: where it
  // sits on the sphere, and where it samples the picture.
  struct Corner
  {
    bool valid{false};
    PatchVertex vertex;
  };

  const auto evaluate = [&](int latitude_index, int longitude_index) {
      Corner corner;
      const double latitude = -M_PI_2 + latitude_index * latitude_step;
      const double longitude = longitude_index * longitude_step;
      const Ogre::Vector3 direction(
        static_cast<Ogre::Real>(std::cos(latitude) * std::cos(longitude)),
        static_cast<Ogre::Real>(std::cos(latitude) * std::sin(longitude)),
        static_cast<Ogre::Real>(std::sin(latitude)));
      const Ogre::Vector3 point_on_sphere = direction * static_cast<Ogre::Real>(radius);

      // Through the camera's own centre, not the sphere's. The offset is what
      // makes this a parallax-correct picture for objects at `radius`, and what
      // makes two cameras disagree about anything nearer or farther.
      const Ogre::Vector3 in_optical_frame = optical_from_base * (point_on_sphere - pose.position);

      double u = 0.0;
      double v = 0.0;
      if (!projectToPixel(camera_info, in_optical_frame, u, v)) {
        return corner;
      }
      if (u < 0.0 || v < 0.0 || u >= width || v >= height) {
        return corner;
      }
      corner.valid = true;
      corner.vertex.position = point_on_sphere;
      corner.vertex.u = static_cast<float>(u / width);
      corner.vertex.v = static_cast<float>(v / height);
      return corner;
    };

  for (int latitude_index = 0; latitude_index < latitude_count; ++latitude_index) {
    for (int longitude_index = 0; longitude_index < longitude_count; ++longitude_index) {
      const Corner bottom_left = evaluate(latitude_index, longitude_index);
      const Corner bottom_right = evaluate(latitude_index, longitude_index + 1);
      const Corner top_left = evaluate(latitude_index + 1, longitude_index);
      const Corner top_right = evaluate(latitude_index + 1, longitude_index + 1);
      if (!bottom_left.valid || !bottom_right.valid || !top_left.valid || !top_right.valid) {
        continue;
      }
      // A cell that straddles the seam of the image would stretch the whole
      // picture across the sphere. Discard rather than clip.
      const float max_span = 0.5f;
      if (std::abs(bottom_left.vertex.u - bottom_right.vertex.u) > max_span ||
        std::abs(bottom_left.vertex.v - top_left.vertex.v) > max_span)
      {
        continue;
      }

      triangles.push_back(bottom_left.vertex);
      triangles.push_back(bottom_right.vertex);
      triangles.push_back(top_right.vertex);

      triangles.push_back(bottom_left.vertex);
      triangles.push_back(top_right.vertex);
      triangles.push_back(top_left.vertex);
    }
  }

  return triangles;
}

}  // namespace golfcart_sphere_view
