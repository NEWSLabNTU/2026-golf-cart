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

#ifndef ARUCO_SIM_DETECTOR__MARKER_PNP_HPP_
#define ARUCO_SIM_DETECTOR__MARKER_PNP_HPP_

#include <golfcart_aruco_localizer/tag_frame.hpp>

#include <Eigen/Geometry>
#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>

#include <algorithm>
#include <vector>

namespace golfcart::aruco_sim
{

/// The two candidate poses of a square marker, best first.
///
/// `error_1 <= error_2`, both in pixels, both computed here rather than taken
/// from OpenCV — see the warning below. `error_1 / error_2` is the ambiguity
/// metric: near 0 the answer is clear, near 1 the marker cannot resolve its own
/// orientation.
struct MarkerPnpResult
{
  Eigen::Isometry3d pose_1{Eigen::Isometry3d::Identity()};
  Eigen::Isometry3d pose_2{Eigen::Isometry3d::Identity()};
  double error_1{0.0};
  double error_2{0.0};
  bool valid{false};
};

namespace detail
{

inline Eigen::Isometry3d toIsometry(const cv::Mat & rvec, const cv::Mat & tvec)
{
  cv::Mat r;
  cv::Rodrigues(rvec, r);
  Eigen::Isometry3d pose = Eigen::Isometry3d::Identity();
  for (int i = 0; i < 3; ++i) {
    for (int j = 0; j < 3; ++j) {
      pose.linear()(i, j) = r.at<double>(i, j);
    }
  }
  pose.translation() = Eigen::Vector3d{
    tvec.at<double>(0), tvec.at<double>(1), tvec.at<double>(2)};
  return pose;
}

/// Worst-corner reprojection error, in pixels.
inline double reprojectionError(
  const Eigen::Isometry3d & pose, const std::array<Eigen::Vector3d,
  aruco_localizer::kNumCorners> & object_points,
  const std::vector<cv::Point2f> & pixels, const Eigen::Matrix3d & k)
{
  double worst = 0.0;
  for (std::size_t i = 0; i < aruco_localizer::kNumCorners; ++i) {
    const Eigen::Vector3d c = pose * object_points[i];
    if (c.z() <= 1e-9) {
      return std::numeric_limits<double>::max();
    }
    const double u = k(0, 0) * c.x() / c.z() + k(0, 2);
    const double v = k(1, 1) * c.y() / c.z() + k(1, 2);
    worst = std::max(worst, std::hypot(u - pixels[i].x, v - pixels[i].y));
  }
  return worst;
}

}  // namespace detail

/// Recover both poses of a square marker from its four rectified corners.
///
/// Corners must be in `aruco_localizer::Corner` order and must already be in
/// the rectified frame, so distortion is zero here by construction.
///
/// WHY THIS IS NOT JUST solvePnPGeneric(SOLVEPNP_IPPE_SQUARE):
///
/// On OpenCV 4.5.4, that call returns poses that do not reproject. Measured on
/// noiseless synthetic corners, the best of its two solutions was off by 2.8 px
/// at a 0.5 rad tilt and by 115 px viewed fronto-parallel, where the correct
/// answer reprojects to zero by construction. `estimatePoseSingleMarkers` looks
/// fine only because on this version it quietly uses SOLVEPNP_ITERATIVE, not
/// IPPE.
///
/// So: take candidates from both ITERATIVE and IPPE, polish every one with
/// `solvePnPRefineLM`, and score them with our own reprojection error rather
/// than trusting the one OpenCV returns. After refinement all the geometries
/// tested recover the true pose to about 1e-5 px, and the ambiguity ratio
/// becomes meaningful — 0.9998 where the view is genuinely two-valued, near
/// zero where it is not.
///
/// The real detector must do the same thing. Skipping the refinement gives a
/// detector that looks like it works and is quietly wrong.
inline MarkerPnpResult solveMarkerPose(
  const std::vector<cv::Point2f> & pixels, double marker_size, const Eigen::Matrix3d & k)
{
  MarkerPnpResult out;
  if (pixels.size() != aruco_localizer::kNumCorners) {
    return out;
  }

  const auto object = aruco_localizer::tagLocalCorners(marker_size);
  std::vector<cv::Point3f> object_cv;
  object_cv.reserve(aruco_localizer::kNumCorners);
  for (const auto & p : object) {
    object_cv.emplace_back(
      static_cast<float>(p.x()), static_cast<float>(p.y()), static_cast<float>(p.z()));
  }

  cv::Mat camera_matrix = (cv::Mat_<double>(3, 3) <<
    k(0, 0), k(0, 1), k(0, 2), k(1, 0), k(1, 1), k(1, 2), k(2, 0), k(2, 1), k(2, 2));
  const cv::Mat distortion = cv::Mat::zeros(5, 1, CV_64F);

  std::vector<std::pair<cv::Mat, cv::Mat>> candidates;
  {
    cv::Mat r;
    cv::Mat t;
    if (cv::solvePnP(object_cv, pixels, camera_matrix, distortion, r, t, false,
      cv::SOLVEPNP_ITERATIVE))
    {
      candidates.emplace_back(r, t);
    }
  }
  {
    std::vector<cv::Mat> rvecs;
    std::vector<cv::Mat> tvecs;
    cv::Mat unused;
    cv::solvePnPGeneric(
      object_cv, pixels, camera_matrix, distortion, rvecs, tvecs, false,
      cv::SOLVEPNP_IPPE_SQUARE, cv::noArray(), cv::noArray(), unused);
    for (std::size_t i = 0; i < rvecs.size(); ++i) {
      candidates.emplace_back(rvecs[i], tvecs[i]);
    }
  }
  if (candidates.empty()) {
    return out;
  }

  std::vector<std::pair<double, Eigen::Isometry3d>> scored;
  for (auto & [r_in, t_in] : candidates) {
    cv::Mat r = r_in.clone();
    cv::Mat t = t_in.clone();
    if (r.type() != CV_64F) {r.convertTo(r, CV_64F);}
    if (t.type() != CV_64F) {t.convertTo(t, CV_64F);}
    cv::solvePnPRefineLM(object_cv, pixels, camera_matrix, distortion, r, t);
    const Eigen::Isometry3d pose = detail::toIsometry(r, t);
    scored.emplace_back(detail::reprojectionError(pose, object, pixels, k), pose);
  }
  std::sort(
    scored.begin(), scored.end(),
    [](const auto & a, const auto & b) {return a.first < b.first;});

  // Distinct solutions only: refining several seeds often lands them on the
  // same answer, and reporting a duplicate as the "alternate" would make every
  // marker look unambiguous.
  std::vector<std::pair<double, Eigen::Isometry3d>> distinct;
  for (const auto & s : scored) {
    const bool dup = std::any_of(
      distinct.begin(), distinct.end(), [&s](const auto & d) {
        return (d.second.translation() - s.second.translation()).norm() < 1e-4 &&
               Eigen::AngleAxisd(d.second.linear().transpose() * s.second.linear()).angle() < 1e-3;
      });
    if (!dup) {
      distinct.push_back(s);
    }
    if (distinct.size() == 2) {
      break;
    }
  }

  out.valid = true;
  out.pose_1 = distinct[0].second;
  out.error_1 = distinct[0].first;
  if (distinct.size() > 1) {
    out.pose_2 = distinct[1].second;
    out.error_2 = distinct[1].first;
  } else {
    // Only one distinct pose. Reporting it twice would give a ratio of 1 and
    // read as maximally ambiguous, which is the opposite of the truth.
    out.pose_2 = distinct[0].second;
    out.error_2 = std::numeric_limits<double>::infinity();
  }
  return out;
}

}  // namespace golfcart::aruco_sim

#endif  // ARUCO_SIM_DETECTOR__MARKER_PNP_HPP_
