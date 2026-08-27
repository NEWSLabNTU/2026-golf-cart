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

#ifndef GOLFCART_SPHERE_VIEW__CAMERA_LAYER_HPP_
#define GOLFCART_SPHERE_VIEW__CAMERA_LAYER_HPP_

#include <rclcpp/rclcpp.hpp>
#include <rviz_common/properties/bool_property.hpp>

#include <sensor_msgs/msg/camera_info.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>
#include <sensor_msgs/msg/image.hpp>

#include <QImage>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

#include "sphere_mesh.hpp"
#include "textured_patch.hpp"

namespace rviz_common
{
class DisplayContext;
namespace properties
{
class EnumProperty;
class FloatProperty;
class RosTopicProperty;
class TfFrameProperty;
}  // namespace properties
}  // namespace rviz_common

namespace golfcart_sphere_view
{

/// One camera on the sphere: its subscriptions, its decode thread, its patch.
///
/// Appears in the Displays panel as a child of the display, so a camera can be
/// switched off without unsubscribing the others, which is how a seam is
/// attributed to one side or the other.
class CameraLayer : public rviz_common::properties::BoolProperty
{
  Q_OBJECT

public:
  CameraLayer(
    const QString & name, const QString & image_topic, const QString & camera_info_topic,
    rviz_common::properties::Property * parent);
  ~CameraLayer() override;

  /// Ogre objects cannot be built in the constructor: the display owns the
  /// scene node and only has it after onInitialize().
  void initialize(rviz_common::DisplayContext * context, Ogre::SceneNode * parent_scene_node);

  /// Frame the projection is done in: the override if set, else CameraInfo's.
  std::string opticalFrame(const sensor_msgs::msg::CameraInfo & camera_info) const;

  void subscribe();
  void unsubscribe();

  /// Rebuild the patch. Cheap to call when nothing changed; it returns early
  /// unless the geometry is marked dirty or `force` is set.
  void updateGeometry(
    const std::string & centre_frame, double radius, const SphereResolution & resolution,
    bool force);

  /// Upload the newest decoded frame, if one arrived since the last call.
  void updateTexture();

  /// True while the layer has an image and a patch to draw it on.
  bool isRendering() const;

  QString statusSummary() const;

private Q_SLOTS:
  void onTopicsChanged();
  void onAlphaChanged();
  void onEnableChanged();

private:
  /// Rate gate: true when this frame is due, false when it should be dropped.
  bool acceptFrameNow();

  void startWorker();
  void stopWorker();
  void workerLoop();

  rviz_common::DisplayContext * context_{nullptr};
  std::unique_ptr<TexturedPatch> patch_;

  rviz_common::properties::RosTopicProperty * image_topic_property_;
  rviz_common::properties::EnumProperty * image_type_property_;
  rviz_common::properties::RosTopicProperty * camera_info_topic_property_;
  rviz_common::properties::TfFrameProperty * optical_frame_property_;
  rviz_common::properties::FloatProperty * alpha_property_;
  rviz_common::properties::FloatProperty * max_rate_property_;

  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr compressed_subscription_;
  rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr raw_subscription_;
  rclcpp::Subscription<sensor_msgs::msg::CameraInfo>::SharedPtr camera_info_subscription_;

  /// A frame as it arrived, before the worker turns it into a QImage.
  ///
  /// Compressed and raw are carried in one slot because the worker treats them
  /// the same way afterwards: decode or wrap, convert to RGB888, hand over.
  struct PendingFrame
  {
    std::vector<uint8_t> bytes;
    // Zero for compressed frames, where the header is in the bytes themselves.
    uint32_t width{0};
    uint32_t height{0};
    uint32_t step{0};
    std::string encoding;
    bool compressed{true};
  };

  // Frame in, decoded frame out. One slot each: this is a monitor, so the
  // newest frame wins and the rest are dropped rather than queued.
  std::mutex encoded_mutex_;
  std::condition_variable encoded_available_;
  PendingFrame encoded_frame_;
  bool has_encoded_frame_{false};

  std::mutex decoded_mutex_;
  QImage decoded_frame_;
  bool has_decoded_frame_{false};

  std::thread worker_;
  std::atomic<bool> worker_running_{false};

  std::mutex camera_info_mutex_;
  sensor_msgs::msg::CameraInfo camera_info_;
  bool has_camera_info_{false};

  bool geometry_dirty_{true};
  bool has_geometry_{false};
  std::size_t triangle_count_{0};
  std::string transform_error_;
  std::size_t decode_failures_{0};
  std::size_t dropped_by_rate_{0};
  std::chrono::steady_clock::time_point last_accepted_{};
  std::string decode_error_;
};

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__CAMERA_LAYER_HPP_
