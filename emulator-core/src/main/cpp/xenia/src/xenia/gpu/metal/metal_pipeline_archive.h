/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Persistent render pipeline cache for the Metal backend, through
 * MTLBinaryArchive (iOS 14+ / macOS 11+).
 *
 * The MSL libraries are compiled from source at runtime, and a runtime library
 * cannot be exported as a metallib on device, so the shader *source* cache is
 * all MetalShaderCache can keep. What can be kept is the backend (GPU machine
 * code) half of each pipeline: Metal looks a pipeline up in the archive by its
 * functions' bitcode hash plus the descriptor state, and skips that compile on
 * a hit. A miss compiles as before and is recorded for the next launch.
 *
 * The archive is per title and per GPU, beside the MSL source cache, with a
 * sidecar holding the OS build, GPU name and schema. Any mismatch (an OS
 * update most often) deletes it: a stale archive only misses, but it would
 * also grow without bound.
 ******************************************************************************
 */

#ifndef XENIA_GPU_METAL_METAL_PIPELINE_ARCHIVE_H_
#define XENIA_GPU_METAL_METAL_PIPELINE_ARCHIVE_H_

#include <atomic>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <mutex>
#include <string>

#include "third_party/metal-cpp/Metal/Metal.hpp"

namespace xe {
namespace gpu {
namespace metal {

class MetalPipelineArchive {
 public:
  MetalPipelineArchive() = default;
  ~MetalPipelineArchive();
  MetalPipelineArchive(const MetalPipelineArchive&) = delete;
  MetalPipelineArchive& operator=(const MetalPipelineArchive&) = delete;

  // Opens (or creates) the archive in `dir`. Safe to call again for another
  // title: the previous one is serialized and closed first.
  void Open(MTL::Device* device, const std::filesystem::path& dir);
  // Writes pending additions and drops the archive.
  void Close();

  bool is_open() const { return archive_ != nullptr; }

  // Creates the pipeline, from the archive when it holds it, compiling and
  // recording it otherwise. Thread-safe; called from the compile workers and
  // the command processor. Falls back to a plain compile when closed.
  MTL::RenderPipelineState* CreateRenderPipelineState(
      MTL::Device* device, MTL::RenderPipelineDescriptor* desc,
      NS::Error** error);

  // Serializes when there is something new and enough time has passed since
  // the last write. Cheap when there is nothing to do.
  void MaybeSerialize();

  uint64_t hits() const { return hits_.load(std::memory_order_relaxed); }
  uint64_t misses() const { return misses_.load(std::memory_order_relaxed); }

 private:
  void OpenLocked(MTL::Device* device, const std::filesystem::path& dir);
  void SerializeLocked();
  void SerializeInPool();

  MTL::Device* device_ = nullptr;
  MTL::BinaryArchive* archive_ = nullptr;
  NS::Array* archive_array_ = nullptr;
  std::filesystem::path archive_path_;
  std::mutex mutex_;
  uint32_t pending_additions_ = 0;
  std::chrono::steady_clock::time_point last_serialize_{};
  std::atomic<uint64_t> hits_{0};
  std::atomic<uint64_t> misses_{0};
  // Additions that failed; after a few the archive is left read-only.
  uint32_t add_failures_ = 0;
};

}  // namespace metal
}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_METAL_METAL_PIPELINE_ARCHIVE_H_
