/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Frame generation for the Vulkan presenter.                                 *
 ******************************************************************************
 */

#ifndef XENIA_UI_VULKAN_VULKAN_FRAME_GENERATOR_H_
#define XENIA_UI_VULKAN_VULKAN_FRAME_GENERATOR_H_

#include <array>
#include <cstdint>
#include <memory>

#include "xenia/ui/vulkan/ui_samplers.h"
#include "xenia/ui/vulkan/vulkan_device.h"

namespace xe {
namespace ui {
namespace vulkan {

// Invents a frame between the two most recent guest images, by estimating
// motion between them and warping both to the midpoint.
//
// The guest gives us no motion vectors, so motion is estimated from the
// presented images alone - the same thing a desktop frame doubler does. What
// that costs is described on the cvar and in the settings UI; the short version
// is that a real frame has to be held back to interpolate towards, and that the
// work is not free on a GPU that may already be the limit.
//
// EVERY image owned by this class stays in VK_IMAGE_LAYOUT_GENERAL for its
// whole life, except the generated frame, which is handed to the paint chain in
// SHADER_READ_ONLY_OPTIMAL because that is the layout the chain's descriptors
// declare. Keeping the rest in GENERAL means the passes need only memory
// barriers between them, never layout transitions - there is no second consumer
// to hand them to.
//
// This class records work; it never submits. The caller owns the command
// buffer, the queue and the synchronization.
class VulkanFrameGenerator {
 public:
  static std::unique_ptr<VulkanFrameGenerator> Create(
      VulkanDevice* vulkan_device, const UISamplers* ui_samplers);

  VulkanFrameGenerator(const VulkanFrameGenerator& generator) = delete;
  VulkanFrameGenerator& operator=(const VulkanFrameGenerator& generator) =
      delete;
  ~VulkanFrameGenerator();

  // Whether a previous guest image has been captured at the current size, so
  // there is something to interpolate from. False after a start, a resize, or
  // any interruption - the first guest image after one of those is presented as
  // it is.
  bool has_history() const { return has_history_; }

  // Records the passes that produce one generated frame from the stored history
  // and `guest_view`, then records the capture of `guest_view` as the new
  // history.
  //
  // `guest_view` must be in VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL for the
  // whole of the recorded range, which is what the refresher leaves it in - this
  // class never transitions it.
  //
  // Returns false if resources for this size could not be prepared, in which
  // case nothing has been recorded and the caller should present the guest image
  // normally. When it returns true, generated_view() is ready to be sampled in
  // the same submission.
  bool RecordGenerateAndCapture(VkCommandBuffer command_buffer,
                                VkImageView guest_view, uint32_t width,
                                uint32_t height, float t);

  // Records only the capture of `guest_view` as the new history, for the first
  // frame at a new size where there is nothing to interpolate from yet.
  bool RecordCaptureOnly(VkCommandBuffer command_buffer, VkImageView guest_view,
                         uint32_t width, uint32_t height);

  // Valid after a successful RecordGenerateAndCapture, in
  // SHADER_READ_ONLY_OPTIMAL. Stable across calls at the same size, so the
  // descriptor written for it only has to be rewritten when it changes.
  VkImageView generated_view() const { return generated_.view; }
  // Bumped whenever generated_view() starts referring to a different image, so
  // the caller knows to rewrite its descriptor.
  uint64_t generated_version() const { return generated_version_; }

  // Forget the history. For a paused guest, a lost surface, or anything else
  // that makes the stored frame no longer the one immediately before the next.
  void DropHistory() { has_history_ = false; }

 private:
  // One pass of the chain. The order here is the order they run in.
  enum Pipeline : size_t {
    kPipelineCopy,
    kPipelineLuma,
    kPipelineSearch,
    kPipelineSmooth,
    kPipelineWarp,

    kPipelineCount,
  };

  // Matches frame_gen_common.h. Kept as one block for every pass so a single
  // pipeline layout serves all of them.
  struct PushConstants {
    float src_texel[2];
    float dst_size[2];
    float px_per_texel[2];
    float lambda;
    float t;
    int32_t taps;
    int32_t mode;
    int32_t steps;
    int32_t use_pred;
    int32_t flip;
  };

  struct Image {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    uint32_t width = 0;
    uint32_t height = 0;
  };

  // Full-resolution pixels per motion vector. Fine enough to follow an object
  // across the screen, coarse enough that the search is affordable and that
  // noise averages out over the block.
  static constexpr uint32_t kBlockSize = 16;
  static constexpr uint32_t kLumaFineDiv = 4;
  static constexpr uint32_t kLumaCoarseDiv = 16;
  static constexpr uint32_t kLocalSize = 8;
  // Descriptor sets are cycled so a set is not rewritten while a previous
  // submission may still be reading it. Seven dispatches per generated frame
  // against three submissions in flight is the number to clear, with room
  // spare - the sets are small and the cost of getting this wrong is reading a
  // descriptor that has been overwritten mid-flight.
  static constexpr uint32_t kDescriptorSetRingSize = 48;

  explicit VulkanFrameGenerator(VulkanDevice* const vulkan_device,
                                const UISamplers* const ui_samplers)
      : vulkan_device_(vulkan_device), ui_samplers_(ui_samplers) {}

  bool Initialize();
  bool EnsureResources(uint32_t width, uint32_t height);
  void DestroyResources();

  bool CreateImage(Image& image, uint32_t width, uint32_t height,
                   VkFormat format, const char* what);
  void DestroyImage(Image& image);

  // A sampled input. The layout travels with the view because the guest output
  // image arrives in SHADER_READ_ONLY_OPTIMAL while everything this class owns
  // stays in GENERAL, and a descriptor whose declared layout does not match the
  // image's actual layout is undefined behaviour, not a warning.
  struct SampledInput {
    VkImageView view = VK_NULL_HANDLE;
    VkImageLayout layout = VK_IMAGE_LAYOUT_GENERAL;
  };

  // Binds three sampled images and one storage image into a fresh set from the
  // ring, then dispatches enough groups to cover `dst`.
  void Dispatch(VkCommandBuffer command_buffer, Pipeline pipeline,
                const SampledInput& src0, const SampledInput& src1,
                const SampledInput& src2, const Image& dst,
                const PushConstants& push);
  // Moves freshly created images out of VK_IMAGE_LAYOUT_UNDEFINED. Recorded
  // once, at the head of the first pass that follows their creation.
  void RecordInitialTransitions(VkCommandBuffer command_buffer);
  // Both levels of the luma pyramid for one image, into `slot`.
  void RecordLumaPyramid(VkCommandBuffer command_buffer,
                         const SampledInput& source, uint32_t source_width,
                         uint32_t source_height, uint32_t slot);
  // A memory barrier between two compute passes on images kept in GENERAL.
  void BarrierComputeToCompute(VkCommandBuffer command_buffer);

  VulkanDevice* vulkan_device_;
  const UISamplers* ui_samplers_;

  VkDescriptorSetLayout descriptor_set_layout_ = VK_NULL_HANDLE;
  VkPipelineLayout pipeline_layout_ = VK_NULL_HANDLE;
  VkDescriptorPool descriptor_pool_ = VK_NULL_HANDLE;
  std::array<VkDescriptorSet, kDescriptorSetRingSize> descriptor_sets_{};
  uint32_t descriptor_set_next_ = 0;
  std::array<VkPipeline, kPipelineCount> pipelines_{};

  // History colour, and the luma pyramid, double buffered: one slot holds the
  // previous frame while the other is being written for the current one.
  Image history_;
  std::array<Image, 2> luma_fine_;
  std::array<Image, 2> luma_coarse_;
  Image mv_coarse_;
  Image mv_fine_;
  Image mv_smooth_;
  Image generated_;
  uint64_t generated_version_ = 0;

  uint32_t current_width_ = 0;
  uint32_t current_height_ = 0;
  uint32_t luma_slot_ = 0;
  bool has_history_ = false;
  bool resources_failed_ = false;
  // Set when images have been created and not yet transitioned out of
  // UNDEFINED.
  bool needs_initial_transitions_ = false;
  // Whether the generated image is currently in SHADER_READ_ONLY_OPTIMAL,
  // handed to the paint chain, rather than in GENERAL.
  bool generated_in_read_layout_ = false;
};

}  // namespace vulkan
}  // namespace ui
}  // namespace xe

#endif  // XENIA_UI_VULKAN_VULKAN_FRAME_GENERATOR_H_
