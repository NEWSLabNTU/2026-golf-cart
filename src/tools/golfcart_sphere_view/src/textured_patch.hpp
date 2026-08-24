/* Copyright 2021 Austrian Institute of Technology GmbH
 * Copyright 2026 NEWSLab, National Taiwan University
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * Derived from nobleo/rviz_satellite src/tile_object.hpp, which draws a map
 * tile as a textured quad. The material setup is kept as it was -- unlit,
 * two-sided, depth-write off -- because a sphere seen from the inside needs
 * exactly that. Two things differ: the geometry is supplied by the caller
 * rather than being a hardcoded quad, and the texture is allocated once and
 * written in place. The original reallocates on every update, which suits map
 * tiles that change when the vehicle drives a block and does not suit three
 * cameras at 30 Hz.
 */
#ifndef GOLFCART_SPHERE_VIEW__TEXTURED_PATCH_HPP_
#define GOLFCART_SPHERE_VIEW__TEXTURED_PATCH_HPP_

#include <OgreMaterial.h>
#include <OgreTexture.h>
#include <OgreVector3.h>

#include <QImage>
#include <string>
#include <vector>

namespace Ogre
{
class ManualObject;
class SceneManager;
class SceneNode;
}  // namespace Ogre

namespace golfcart_sphere_view
{

/// One vertex of a patch: where it sits, and where it samples the image.
struct PatchVertex
{
  Ogre::Vector3 position;
  float u;
  float v;
};

/// A textured surface in the scene, fed from a live image.
///
/// Geometry and texture are independent: setGeometry() is called when the
/// calibration or the transform changes, updateImage() on every frame.
class TexturedPatch
{
public:
  TexturedPatch(
    Ogre::SceneManager * scene_manager, Ogre::SceneNode * parent_scene_node,
    const std::string & unique_id);
  ~TexturedPatch();

  TexturedPatch(const TexturedPatch &) = delete;
  TexturedPatch & operator=(const TexturedPatch &) = delete;

  /// Replace the mesh. Triangles are taken three vertices at a time.
  void setGeometry(const std::vector<PatchVertex> & triangles);

  /// Upload a frame. Reallocates only when the image size or format changes.
  void updateImage(const QImage & image);

  void setAlpha(float alpha);
  void setVisible(bool visible);
  bool hasGeometry() const { return has_geometry_; }

private:
  void setupMaterial();
  void ensureTexture(std::size_t width, std::size_t height, Ogre::PixelFormat format);

  Ogre::SceneManager * scene_manager_;
  Ogre::SceneNode * scene_node_;
  Ogre::ManualObject * manual_object_;
  Ogre::MaterialPtr material_;
  Ogre::TexturePtr texture_;
  std::string unique_id_;

  std::size_t texture_width_{0};
  std::size_t texture_height_{0};
  Ogre::PixelFormat texture_format_{Ogre::PF_UNKNOWN};
  bool has_geometry_{false};
};

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__TEXTURED_PATCH_HPP_
