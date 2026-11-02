/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_GPU_GPU_LIVE_OPTIONS_H_
#define XENIA_GPU_GPU_LIVE_OPTIONS_H_

#include <atomic>
#include <cstddef>
#include <cstdint>

namespace xe {
namespace gpu {

// GPU options the in-game menu changes while a title runs (through JNI on
// Android). The command processor copies them into their cvars once a frame on
// its own thread, the only reader of those cvars - like the debug.xendroid.*
// properties, but from the app. kLiveOptionUnset keeps the cvar as the config
// set it at launch.
enum class LiveOption : uint32_t {
  // vulkan_async_skip_draws: 0 or 1.
  kAsyncSkipDraws,
  // msaa_4x_as_2x: 0 or 1.
  kMsaa4xAs2x,
  // alpha_to_coverage_as_alpha_test: 0 or 1.
  kAlphaToCoverageAsAlphaTest,
  // vulkan_shading_rate: 0 to 3.
  kShadingRate,

  kCount,
};

constexpr int32_t kLiveOptionUnset = INT32_MIN;

inline std::atomic<int32_t>& LiveOptionValue(LiveOption option) {
  struct Values {
    std::atomic<int32_t> values[size_t(LiveOption::kCount)];
    Values() {
      for (std::atomic<int32_t>& value : values) {
        value.store(kLiveOptionUnset, std::memory_order_relaxed);
      }
    }
  };
  static Values values;
  return values.values[size_t(option)];
}

}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_GPU_LIVE_OPTIONS_H_
