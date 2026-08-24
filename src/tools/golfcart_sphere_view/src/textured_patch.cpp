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
 * Derived from nobleo/rviz_satellite src/tile_object.cpp.
 */
#include "textured_patch.hpp"

#include <OgreHardwarePixelBuffer.h>
#include <OgreManualObject.h>
#include <OgreMaterialManager.h>
#include <OgreSceneManager.h>
#include <OgreSceneNode.h>
#include <OgreTechnique.h>
#include <OgreTextureManager.h>

#include <rviz_rendering/material_manager.hpp>

#include <algorithm>
#include <string>
#include <vector>

namespace golfcart_sphere_view
{

TexturedPatch::TexturedPatch(
  Ogre::SceneManager * scene_manager, Ogre::SceneNode * parent_scene_node,
  const std::string & unique_id)
: scene_manager_(scene_manager), manual_object_(nullptr), unique_id_(unique_id)
{
  setupMaterial();
  manual_object_ = scene_manager_->createManualObject("TexturedPatch/" + unique_id_);
  manual_object_->setDynamic(true);
  scene_node_ = parent_scene_node->createChildSceneNode();
  scene_node_->attachObject(manual_object_);
}

TexturedPatch::~TexturedPatch()
{
  if (texture_) {
    Ogre::TextureManager::getSingleton().remove(texture_);
  }
  if (material_) {
    Ogre::MaterialManager::getSingleton().remove(material_);
  }
  if (manual_object_) {
    scene_node_->detachObject(manual_object_);
    scene_manager_->destroyManualObject(manual_object_);
  }
  if (scene_node_) {
    scene_manager_->destroySceneNode(scene_node_);
  }
}

void TexturedPatch::setupMaterial()
{
  material_ = rviz_rendering::MaterialManager::createMaterialWithNoLighting(unique_id_);
  // Seen from the centre of the sphere, every patch faces away from the camera
  // by Ogre's winding rule, so culling has to be off rather than reversed --
  // the same patch is legitimately viewable from either side while the user
  // orbits.
  material_->setCullingMode(Ogre::CULL_NONE);
  material_->setDepthWriteEnabled(false);
  auto * texture_unit_state = material_->getTechnique(0)->getPass(0)->createTextureUnitState();
  texture_unit_state->setTextureFiltering(Ogre::TFO_BILINEAR);
  // The sphere is a backdrop: clamp so the edge pixels of a camera patch do not
  // wrap around and paint the far side of the image onto the seam.
  texture_unit_state->setTextureAddressingMode(Ogre::TextureUnitState::TAM_CLAMP);
}

void TexturedPatch::setGeometry(const std::vector<PatchVertex> & triangles)
{
  has_geometry_ = triangles.size() >= 3;
  if (!has_geometry_) {
    manual_object_->clear();
    return;
  }

  manual_object_->clear();
  manual_object_->estimateVertexCount(triangles.size());
  manual_object_->begin(
    material_->getName(), Ogre::RenderOperation::OT_TRIANGLE_LIST, "rviz_rendering");
  for (const auto & vertex : triangles) {
    manual_object_->position(vertex.position);
    manual_object_->textureCoord(vertex.u, vertex.v);
    // Pointing back at the sphere centre. Nothing shades this material, but
    // Ogre expects the channel to be present when it is declared.
    manual_object_->normal(-vertex.position.normalisedCopy());
  }
  manual_object_->end();
}

void TexturedPatch::ensureTexture(
  std::size_t width, std::size_t height, Ogre::PixelFormat format)
{
  if (texture_ && texture_width_ == width && texture_height_ == height &&
    texture_format_ == format)
  {
    return;
  }
  if (texture_) {
    Ogre::TextureManager::getSingleton().remove(texture_);
    texture_.reset();
  }
  texture_ = Ogre::TextureManager::getSingleton().createManual(
    "TexturedPatchTex/" + unique_id_, "rviz_rendering", Ogre::TEX_TYPE_2D,
    static_cast<Ogre::uint>(width), static_cast<Ogre::uint>(height), 0, format,
    Ogre::TU_DYNAMIC_WRITE_ONLY_DISCARDABLE);
  texture_width_ = width;
  texture_height_ = height;
  texture_format_ = format;
  material_->getTechnique(0)->getPass(0)->getTextureUnitState(0)->setTextureName(
    texture_->getName());
}

void TexturedPatch::updateImage(const QImage & image)
{
  if (image.isNull()) {
    return;
  }
  // Ogre's PF_BYTE_RGB matches QImage::Format_RGB888 byte for byte, so the
  // conversion happens once here rather than per pixel below.
  const QImage source =
    image.format() == QImage::Format_RGB888 ? image : image.convertToFormat(QImage::Format_RGB888);

  ensureTexture(
    static_cast<std::size_t>(source.width()), static_cast<std::size_t>(source.height()),
    Ogre::PF_BYTE_RGB);

  auto pixel_buffer = texture_->getBuffer();
  pixel_buffer->lock(Ogre::HardwareBuffer::HBL_DISCARD);
  const Ogre::PixelBox & pixel_box = pixel_buffer->getCurrentLock();
  auto * destination = static_cast<uint8_t *>(pixel_box.data);

  // rowPitch counts pixels, not bytes, and Ogre may pad rows, so copy one row
  // at a time rather than assuming the buffer is contiguous.
  const std::size_t source_stride = static_cast<std::size_t>(source.bytesPerLine());
  const std::size_t row_bytes = static_cast<std::size_t>(source.width()) * 3u;
  const std::size_t destination_stride = pixel_box.rowPitch * 3u;
  for (int row = 0; row < source.height(); ++row) {
    std::copy_n(
      source.constScanLine(row), std::min(row_bytes, source_stride),
      destination + static_cast<std::size_t>(row) * destination_stride);
  }
  pixel_buffer->unlock();
}

void TexturedPatch::setAlpha(float alpha)
{
  if (alpha > 0.998f) {
    material_->setDepthWriteEnabled(true);
    material_->setSceneBlending(Ogre::SBT_REPLACE);
  } else {
    material_->setDepthWriteEnabled(false);
    material_->setSceneBlending(Ogre::SBT_TRANSPARENT_ALPHA);
  }
  auto * texture_unit = material_->getTechnique(0)->getPass(0)->getTextureUnitState(0);
  texture_unit->setAlphaOperation(
    Ogre::LBX_SOURCE1, Ogre::LBS_MANUAL, Ogre::LBS_CURRENT, alpha);
}

void TexturedPatch::setVisible(bool visible) { scene_node_->setVisible(visible); }

}  // namespace golfcart_sphere_view
