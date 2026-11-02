/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// texture_load_r11g11b10_rgba16_snorm with whole-cache-line guest loads per instruction
// (vulkan_texture_load_coalesced).
#define XE_TEXTURE_LOAD_32BPB_TO_64BPB_COALESCED 1
#include "pixel_formats.xesli"
#define XE_TEXTURE_LOAD_32BPB_TO_64BPB XeR11G11B10SNormToRGBA16
#include "texture_load_32bpb_64bpb.xesli"
