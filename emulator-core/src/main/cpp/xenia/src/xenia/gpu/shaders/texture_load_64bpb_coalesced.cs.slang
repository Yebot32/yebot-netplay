/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

// texture_load_64bpb with whole-cache-line accesses per instruction
// (vulkan_texture_load_coalesced).
#define XE_TEXTURE_LOAD_64BPB_COALESCED 1
#define XE_TEXTURE_LOAD_64BPB_TRANSFORM(blocks) (blocks)
#include "texture_load_64bpb.xesli"
