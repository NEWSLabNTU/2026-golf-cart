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
#include <sensor_msgs/msg/imu.hpp>
#include <geometry_msgs/msg/twist_with_covariance_stamped.hpp>

#include <random>

#include <tf2_ros/static_transform_broadcaster.h>
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
    imu_frame_id_ = declare_parameter<std::string>("imu_frame_id", "imu_link");

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

    // The EKF cannot run on pose alone: gyro_odometer needs a rate and a speed,
    // and without them the fused output never moves between ArUco fixes. The
    // trajectory already knows both exactly, so they are published from the
    // same source rather than differentiated back out of the pose.
    // RELIABLE, not SensorDataQoS. gyro_odometer subscribes reliably, and a
    // best-effort publisher is simply refused: "offering incompatible QoS. No
    // messages will be sent to it." Every node stays up and looks healthy while
    // the twist chain is silently disconnected.
    imu_publisher_ = create_publisher<sensor_msgs::msg::Imu>(
      "~/output/imu", rclcpp::QoS(10));
    velocity_publisher_ = create_publisher<geometry_msgs::msg::TwistWithCovarianceStamped>(
      "~/output/velocity", rclcpp::QoS(10));

    // Noise is on by default. A dead-reckoning chain fed perfect rates does not
    // drift, which would make DEAD_RECKONING look survivable for far longer than
    // it is and would quietly invalidate every budget measured against it.
    gyro_noise_ = declare_parameter<double>("gyro_noise", 0.002);        // [rad/s]
    gyro_bias_ = declare_parameter<double>("gyro_bias", 0.001);          // [rad/s]
    velocity_noise_ = declare_parameter<double>("velocity_noise", 0.02);  // [m/s]
    rng_.seed(static_cast<std::uint32_t>(declare_parameter<int>("seed", 42)));

    // gyro_odometer transforms the IMU into base_link before using it, so with
    // no base_link -> imu_link transform it silently drops every message and
    // publishes nothing. The EKF then has no twist, produces no output, and the
    // whole fusion chain is dead while every individual node looks healthy.
    //
    // Broadcast from here because this node is what publishes the IMU. Identity
    // on purpose: the trajectory's angular rate IS the body rate, so giving the
    // simulated IMU an offset would mean modelling a lever arm that the rates
    // themselves do not have.
    static_tf_ = std::make_unique<tf2_ros::StaticTransformBroadcaster>(*this);
    geometry_msgs::msg::TransformStamped imu_tf;
    imu_tf.header.stamp = now();
    imu_tf.header.frame_id = child_frame_id_;
    imu_tf.child_frame_id = imu_frame_id_;
    imu_tf.transform.rotation.w = 1.0;
    static_tf_->sendTransform(imu_tf);
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
      // Out and back, so a long run stays inside the board layout. The return
      // leg REVERSES rather than turning around: yaw stays 0 and the body
      // velocity goes negative.
      //
      // It used to flip yaw to pi at the turnaround while still reporting
      // wz = 0, which is not a motion any vehicle can perform. The gyro said
      // "not rotating" while the truth rotated 180 degrees instantly, so the
      // filter could not possibly follow -- it ran 180 degrees out and
      // accumulated tens of metres of along-track error, and every scenario
      // built on this pattern failed for a reason that had nothing to do with
      // the localizer.
      const double period = 2.0 * length_ / std::max(speed_, 1e-6);
      const double phase = std::fmod(t, period);
      const bool outbound = phase < period / 2.0;
      const double s = outbound ? speed_ * phase : length_ - speed_ * (phase - period / 2.0);
      x = origin_x_ + s;
      yaw = 0.0;
      vx = outbound ? speed_ : -speed_;
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
      // Clamped, NOT wrapped. fmod sent the vehicle back to the start
      // instantaneously at the end of the route -- a teleport that no filter
      // can follow, and it showed up as the corridor scenario diverging by
      // 17 m in its final seconds while tracking to a centimetre before that.
      // Running off the end of the route and stopping is honest; jumping is
      // not.
      const double s = std::min(speed_ * t, total);
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

    const auto stamp = msg.header.stamp;

    sensor_msgs::msg::Imu imu;
    imu.header.stamp = stamp;
    // The IMU frame, not base_link: imu_corrector and gyro_odometer both expect
    // the sensor's own frame and transform it themselves.
    imu.header.frame_id = imu_frame_id_;
    imu.orientation = msg.pose.pose.orientation;
    imu.angular_velocity.z = wz + gyro_bias_ + noise(gyro_noise_);
    // Diagonal covariances, since the axes are independent here by construction.
    imu.angular_velocity_covariance[8] = gyro_noise_ * gyro_noise_;
    imu.linear_acceleration_covariance[0] = 1.0;
    imu.linear_acceleration_covariance[4] = 1.0;
    imu.linear_acceleration_covariance[8] = 1.0;
    imu_publisher_->publish(imu);

    geometry_msgs::msg::TwistWithCovarianceStamped velocity;
    velocity.header.stamp = stamp;
    velocity.header.frame_id = child_frame_id_;
    velocity.twist.twist.linear.x = vx + noise(velocity_noise_);
    velocity.twist.twist.angular.z = wz + gyro_bias_ + noise(gyro_noise_);
    velocity.twist.covariance[0] = velocity_noise_ * velocity_noise_;
    velocity.twist.covariance[35] = gyro_noise_ * gyro_noise_;
    velocity_publisher_->publish(velocity);
  }

  double noise(double sigma)
  {
    if (sigma <= 0.0) {
      return 0.0;
    }
    std::normal_distribution<double> distribution(0.0, sigma);
    return distribution(rng_);
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
  rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr imu_publisher_;
  rclcpp::Publisher<geometry_msgs::msg::TwistWithCovarianceStamped>::SharedPtr
    velocity_publisher_;
  std::string imu_frame_id_;
  double gyro_noise_{};
  double gyro_bias_{};
  double velocity_noise_{};
  std::mt19937 rng_;
  std::unique_ptr<tf2_ros::StaticTransformBroadcaster> static_tf_;
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
