/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_GPU_VULKAN_VULKAN_FRAME_INSPECTOR_H_
#define XENIA_GPU_VULKAN_VULKAN_FRAME_INSPECTOR_H_

#include <cstdint>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>

#include "xenia/gpu/render_target_cache.h"
#include "xenia/gpu/vulkan/vulkan_render_target_cache.h"
#include "xenia/ui/vulkan/vulkan_provider.h"

DECLARE_bool(frame_inspector);

namespace xe {
namespace gpu {
namespace vulkan {

class VulkanCommandProcessor;

// Captures the contents of every guest render target at every render pass
// boundary, for a short run of consecutive guest frames, and writes them out as
// PNGs with an HTML report.
//
// This exists because the artifacts worth chasing on this console are not
// crashes and not single-frame errors: they are wrong pixels, and usually wrong
// only in some frames. Logs can say which draws ran and the validation layer
// can say whether the API was used legally, but neither can show that far
// geometry beat near geometry, and neither can show something that is only
// wrong every other frame. Three things follow from that, and they are the
// whole design:
//
//   - DEPTH IS CAPTURED, not just colour. Most of this console's artifact
//     classes are depth-resolution failures, and depth is exactly what a
//     screenshot cannot show.
//   - DEPTH IS RESCALED BEFORE IT IS WRITTEN. A far plane occupies a sliver at
//     the top of the depth range, so a literal greyscale of it is a white
//     rectangle. Every depth image is also written contrast-stretched over its
//     own min/max, and as the residual against the guest's own 20e4 float24
//     quantisation, which is where the precision actually runs out.
//   - CONSECUTIVE FRAMES ARE DIFFED AUTOMATICALLY. Temporal artifacts are the
//     hard ones and diffing frames by hand is slow and easy to get wrong: the
//     region has to be chosen deliberately or the metric measures the HUD's
//     digits or the drift of a texture that is legitimately moving. Capturing
//     per render pass and per attachment picks the region structurally instead,
//     and each diff is written amplified so the SHAPE of the change is visible
//     rather than just a pixel count.
//
// Everything is off unless frame_inspector is set, and the cost when off is a
// null check per render pass. The cvar is read when render targets are created,
// so it has to be set in the config before launch, not toggled mid-run - see
// the usage flag note in VulkanRenderTargetCache::CreateRenderTarget.
class VulkanFrameInspector {
 public:
  explicit VulkanFrameInspector(VulkanCommandProcessor& command_processor);
  ~VulkanFrameInspector();

  // Whether the current guest frame is being captured. Callers should check
  // this before doing any work to build arguments for CapturePass.
  bool capturing() const { return capturing_; }

  // Whether anything at all can be captured - false once the run is over, so
  // the per-frame hook can retire itself.
  bool active() const { return active_; }

  // Called at the guest frame boundary, before the frame counter advances.
  // Finishes the frame that just ended (reading back and writing out what was
  // copied during it) and decides whether the next one is captured.
  void OnGuestFrameEnd(uint64_t frame_index);

  // Called at the end of EndRenderPass, once the pass is closed and copies are
  // legal again. Records copies of the render targets that were attached to the
  // pass into the readback buffer. Does nothing unless capturing.
  void CapturePass();

  // Records a draw against the pass currently being built, so the report can
  // name the geometry in each pass by its guest shaders rather than by index.
  void RecordDraw(uint64_t vertex_shader_hash, uint64_t pixel_shader_hash);

 private:
  // One render target copied out of one render pass.
  struct Capture {
    uint32_t pass_index;
    // -1 for depth, 0...3 for the colour attachment index.
    int32_t attachment;
    // Guest-side description, flattened - see InspectorAttachment.
    uint32_t base_tiles;
    uint32_t pitch_tiles_at_32bpp;
    uint32_t resource_format;
    VkFormat format;
    uint32_t width;
    uint32_t height;
    VkDeviceSize buffer_offset;
    VkDeviceSize buffer_size;
  };

  // One render pass within a captured frame.
  struct PassRecord {
    uint32_t pass_index;
    VulkanRenderTargetCache::RenderPassKey pass_key;
    uint32_t width;
    uint32_t height;
    std::vector<std::pair<uint64_t, uint64_t>> draws;
    // Filled in when the pass had render targets that could not be copied, so
    // the report can say why a pass is missing rather than just omitting it.
    std::string skipped_reason;
  };

  // A decoded image kept so the next frame's matching image can be diffed
  // against it.
  struct PreviousImage {
    uint32_t pass_index;
    int32_t attachment;
    uint32_t width;
    uint32_t height;
    std::vector<uint8_t> rgba;
    // Raw depth in guest units, empty for colour. Diffing the decoded greyscale
    // would quantise the difference to 1/255 and hide exactly the small depth
    // movements this is looking for.
    std::vector<float> depth;
  };

  bool EnsureReadbackBuffer(VkDeviceSize size);
  void DestroyReadbackBuffer();

  void BeginCaptureFrame(uint64_t frame_index);
  void FinishCaptureFrame();

  // Copies one render target into the readback buffer, appending a Capture.
  // Returns false with a reason if it could not be copied.
  bool CaptureRenderTarget(
      const VulkanRenderTargetCache::InspectorAttachment& attachment,
      uint32_t pass_index, int32_t attachment_index, uint32_t width,
      uint32_t height, std::string& reason_out);

  // Decodes one capture out of the mapped readback buffer and writes its PNGs,
  // returning the HTML fragment describing it.
  std::string WriteCapture(const Capture& capture, const uint8_t* data);

  void WriteReport();

  VulkanCommandProcessor& command_processor_;

  bool active_ = false;
  bool capturing_ = false;
  uint64_t capture_start_frame_ = 0;
  uint64_t frames_captured_ = 0;
  uint64_t current_frame_index_ = 0;

  std::filesystem::path output_root_;
  std::filesystem::path frame_directory_;

  VkBuffer readback_buffer_ = VK_NULL_HANDLE;
  VkDeviceMemory readback_memory_ = VK_NULL_HANDLE;
  VkDeviceSize readback_capacity_ = 0;
  VkDeviceSize readback_used_ = 0;

  uint32_t pass_index_ = 0;
  std::vector<Capture> captures_;
  std::vector<PassRecord> passes_;
  std::vector<PreviousImage> previous_images_;
  std::vector<PreviousImage> current_images_;

  // Accumulated HTML, one section per captured frame.
  std::string report_body_;
};

}  // namespace vulkan
}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_VULKAN_VULKAN_FRAME_INSPECTOR_H_
