/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// texture_load_64bpb storing straight into the image
// (vulkan_texture_load_to_image).
#define XE_TEXTURE_LOAD_64BPB_IMAGE 1
#define XE_TEXTURE_LOAD_64BPB_TRANSFORM(blocks) (blocks)
#include "texture_load_64bpb.xesli"
