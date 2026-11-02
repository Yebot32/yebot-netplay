/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// texture_load_depth_unorm storing straight into the image
// (vulkan_texture_load_to_image).
#define XE_TEXTURE_LOAD_32BPB_IMAGE 1
#include "pixel_formats.xesli"
#define XE_TEXTURE_LOAD_32BPB_TRANSFORM(blocks) \
  (float_bits_to_uint_xe(XeUNorm24To32((blocks) >> 8u)))
#include "texture_load_32bpb.xesli"
