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

#include "jpeg_decode.hpp"

#include <csetjmp>
#include <cstdio>

#include <jpeglib.h>

namespace golfcart_sphere_view
{
namespace
{

/// libjpeg reports fatal errors by calling error_exit and not returning. The
/// default implementation calls exit(), which in a viewer means one malformed
/// frame takes RViz with it, so it is replaced with a longjmp back to the
/// caller.
struct JumpingErrorManager
{
  jpeg_error_mgr base;
  jmp_buf escape;
  char message[JMSG_LENGTH_MAX];
};

void escapeOnError(j_common_ptr info)
{
  auto * manager = reinterpret_cast<JumpingErrorManager *>(info->err);
  (*info->err->format_message)(info, manager->message);
  longjmp(manager->escape, 1);
}

void stayQuiet(j_common_ptr, int) {}

}  // namespace

int jpegScaleNumerator(int stored_width, int width_limit)
{
  if (width_limit <= 0 || stored_width <= 0 || stored_width <= width_limit) {
    return 8;
  }
  // Largest reduction that still meets the limit, among the fractions libjpeg
  // makes cheap. Anything finer costs a full decode plus a resample, which is
  // the trade this function exists to avoid.
  for (int numerator : {1, 2, 4}) {
    if (stored_width * numerator / 8 >= width_limit) {
      return numerator;
    }
  }
  return 8;
}

QImage decodeJpeg(const std::vector<uint8_t> & data, int width_limit, std::string & reason)
{
  if (data.size() < 4 || data[0] != 0xFF || data[1] != 0xD8) {
    reason = "not a JPEG";
    return QImage();
  }

  jpeg_decompress_struct info{};
  JumpingErrorManager error{};
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = escapeOnError;
  error.base.emit_message = stayQuiet;

  if (setjmp(error.escape)) {
    jpeg_destroy_decompress(&info);
    reason = error.message[0] != '\0' ? error.message : "libjpeg failed";
    return QImage();
  }

  jpeg_create_decompress(&info);
  jpeg_mem_src(&info, data.data(), static_cast<unsigned long>(data.size()));
  jpeg_read_header(&info, TRUE);

  info.scale_num = static_cast<unsigned int>(
    jpegScaleNumerator(static_cast<int>(info.image_width), width_limit));
  info.scale_denom = 8;
  info.out_color_space = JCS_EXT_RGB;

  jpeg_start_decompress(&info);

  QImage image(
    static_cast<int>(info.output_width), static_cast<int>(info.output_height),
    QImage::Format_RGB888);
  while (info.output_scanline < info.output_height) {
    JSAMPROW row = image.scanLine(static_cast<int>(info.output_scanline));
    jpeg_read_scanlines(&info, &row, 1);
  }

  jpeg_finish_decompress(&info);
  jpeg_destroy_decompress(&info);
  reason.clear();
  return image;
}

}  // namespace golfcart_sphere_view
