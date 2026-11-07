/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_GPU_METAL_METAL_UPLOAD_BUFFER_POOL_H_
#define XENIA_GPU_METAL_METAL_UPLOAD_BUFFER_POOL_H_

#include <cstddef>
#include <cstdint>

#include "third_party/metal-cpp/Metal/Metal.hpp"
#include "xenia/ui/graphics_upload_buffer_pool.h"

namespace xe {
namespace gpu {
namespace metal {

// Shared-storage MTL::Buffer pages, reclaimed once the GPU is done with the
// submission (or frame) index that last used them. From XeniOS a446c62e2,
// which keeps it in ui/metal; it lives here because only the primitive
// processor uses it.
class MetalUploadBufferPool : public ui::GraphicsUploadBufferPool {
 public:
  // The label must outlive the pool.
  MetalUploadBufferPool(MTL::Device* device, const char* label,
                        size_t page_size = kDefaultPageSize);

  uint8_t* Request(uint64_t submission_index, size_t size, size_t alignment,
                   MTL::Buffer*& buffer_out, size_t& offset_out);

 protected:
  Page* CreatePageImplementation() override;

 private:
  struct MetalPage : public Page {
    // Takes ownership of the buffer.
    explicit MetalPage(MTL::Buffer* buffer)
        : buffer_(buffer), mapping_(buffer->contents()) {}
    ~MetalPage() override;
    MTL::Buffer* buffer_;
    void* mapping_;
  };

  MTL::Device* device_;
  const char* label_;
};

}  // namespace metal
}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_METAL_METAL_UPLOAD_BUFFER_POOL_H_
