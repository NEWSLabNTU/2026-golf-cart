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
//
// Scripted ground-truth pose. Stage one of phase 3D-3: no Autoware simulator,
// no map, nothing else running — enough to develop the whole solve against.

#include <rclcpp/rclcpp.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <tf2/LinearMath/Quaternion.h>

#include <cmath>
#include <memory>
#include <string>

namespace golfcart::aruco_sim
{

class TrajectoryPublisherNode : public rclcpp::Node
{
public:
  explicit TrajectoryPublisherNode(const rclcpp::NodeOptions & options)
  : rclcpp::Node("sim_trajectory_publisher", options)
  {
    pattern_ = declare_parameter<std::string>("pattern", "straight");
    speed_ = declare_parameter<double>("speed", 1.0);
    rate_hz_ = declare_parameter<double>("rate", 30.0);
    length_ = declare_parameter<double>("length", 10.0);
    radius_ = declare_parameter<double>("radius", 4.0);
    origin_x_ = declare_parameter<double>("origin_x", 0.0);
    origin_y_ = declare_parameter<double>("origin_y", 0.0);
    frame_id_ = declare_parameter<std::string>("frame_id", "map");
    child_frame_id_ = declare_parameter<std::string>("child_frame_id", "base_link");

    if (pattern_ != "static" && pattern_ != "straight" && pattern_ != "circle" &&
      pattern_ != "corridor")
    {
      throw std::runtime_error(
        "pattern must be one of: static, straight, circle, corridor (got '" + pattern_ + "')");
    }
    if (rate_hz_ <= 0.0) {
      throw std::runtime_error("rate must be positive");
    }

    publisher_ = create_publisher<nav_msgs::msg::Odometry>("~/output/ground_truth",
      rclcpp::QoS(10));
    timer_ = create_wall_timer(
      std::chrono::duration<double>(1.0 / rate_hz_), [this]() { tick(); });

    RCLCPP_INFO(
      get_logger(), "publishing '%s' ground truth at %.1f Hz, %.2f m/s",
      pattern_.c_str(), rate_hz_, speed_);
  }

private:
  void tick()
  {
    const double t = elapsed_;
    elapsed_ += 1.0 / rate_hz_;

    double x = origin_x_;
    double y = origin_y_;
    double yaw = 0.0;
    double vx = speed_;
    double wz = 0.0;

    if (pattern_ == "static") {
      vx = 0.0;
    } else if (pattern_ == "straight") {
      // Out and back, so a long run stays inside the board layout.
      const double period = 2.0 * length_ / std::max(speed_, 1e-6);
      const double phase = std::fmod(t, period);
      const bool outbound = phase < period / 2.0;
      const double s = outbound ? speed_ * phase : length_ - speed_ * (phase - period / 2.0);
      x = origin_x_ + s;
      yaw = outbound ? 0.0 : M_PI;
    } else if (pattern_ == "circle") {
      wz = speed_ / std::max(radius_, 1e-6);
      const double a = wz * t;
      x = origin_x_ + radius_ * std::cos(a);
      y = origin_y_ + radius_ * std::sin(a);
      yaw = a + M_PI_2;
    } else {  // corridor: straight, 90 degree turn, straight
      const double leg = length_;
      const double turn_arc = M_PI_2 * radius_;
      const double total = 2.0 * leg + turn_arc;
      const double s = std::fmod(speed_ * t, total);
      if (s < leg) {
        x = origin_x_ + s;
        yaw = 0.0;
      } else if (s < leg + turn_arc) {
        const double a = (s - leg) / std::max(radius_, 1e-6);
        x = origin_x_ + leg + radius_ * std::sin(a);
        y = origin_y_ + radius_ * (1.0 - std::cos(a));
        yaw = a;
        wz = speed_ / std::max(radius_, 1e-6);
      } else {
        const double d = s - leg - turn_arc;
        x = origin_x_ + leg + radius_;
        y = origin_y_ + radius_ + d;
        yaw = M_PI_2;
      }
    }

    nav_msgs::msg::Odometry msg;
    msg.header.stamp = now();
    msg.header.frame_id = frame_id_;
    msg.child_frame_id = child_frame_id_;
    msg.pose.pose.position.x = x;
    msg.pose.pose.position.y = y;
    msg.pose.pose.position.z = 0.0;

    tf2::Quaternion q;
    q.setRPY(0.0, 0.0, yaw);
    msg.pose.pose.orientation.x = q.x();
    msg.pose.pose.orientation.y = q.y();
    msg.pose.pose.orientation.z = q.z();
    msg.pose.pose.orientation.w = q.w();

    msg.twist.twist.linear.x = vx;
    msg.twist.twist.angular.z = wz;

    publisher_->publish(msg);
  }

  std::string pattern_;
  std::string frame_id_;
  std::string child_frame_id_;
  double speed_{};
  double rate_hz_{};
  double length_{};
  double radius_{};
  double origin_x_{};
  double origin_y_{};
  double elapsed_{0.0};

  rclcpp::Publisher<nav_msgs::msg::Odometry>::SharedPtr publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
};

}  // namespace golfcart::aruco_sim

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    rclcpp::spin(
      std::make_shared<golfcart::aruco_sim::TrajectoryPublisherNode>(rclcpp::NodeOptions{}));
  } catch (const std::exception & e) {
    RCLCPP_FATAL(rclcpp::get_logger("sim_trajectory_publisher"), "startup failed: %s", e.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
