/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// texture_load_r10g11b11_rgba16_snorm storing straight into the image
// (vulkan_texture_load_to_image).
#define XE_TEXTURE_LOAD_32BPB_TO_64BPB_IMAGE 1
#include "pixel_formats.xesli"
#define XE_TEXTURE_LOAD_32BPB_TO_64BPB XeR10G11B11SNormToRGBA16
#include "texture_load_32bpb_64bpb.xesli"
