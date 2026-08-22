/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Frame generation for the Vulkan presenter.                                 *
 ******************************************************************************
 */

#include "xenia/ui/vulkan/vulkan_frame_generator.h"

#include <algorithm>
#include <cstring>

#include "xenia/base/logging.h"
#include "xenia/ui/vulkan/vulkan_util.h"

#include "xenia/ui/shaders/bytecode/vulkan_spirv/frame_gen_copy_cs.h"
#include "xenia/ui/shaders/bytecode/vulkan_spirv/frame_gen_luma_cs.h"
#include "xenia/ui/shaders/bytecode/vulkan_spirv/frame_gen_search_cs.h"
#include "xenia/ui/shaders/bytecode/vulkan_spirv/frame_gen_smooth_cs.h"
#include "xenia/ui/shaders/bytecode/vulkan_spirv/frame_gen_warp_cs.h"

namespace xe {
namespace ui {
namespace vulkan {

namespace {

// Every format used here is one core Vulkan guarantees as a storage image, so
// there is no capability to query and no fallback to write. R32_SFLOAT for luma
// is more precision than luma needs, but R8_UNORM is not on the guaranteed list
// and the pyramid levels are small enough that it does not matter.
constexpr VkFormat kColorFormat = VK_FORMAT_R16G16B16A16_SFLOAT;
constexpr VkFormat kLumaFormat = VK_FORMAT_R32_SFLOAT;
constexpr VkFormat kMotionFormat = VK_FORMAT_R32G32_SFLOAT;

constexpr uint32_t DivideRoundingUp(uint32_t value, uint32_t divisor) {
  return (value + divisor - 1) / divisor;
}

}  // namespace

std::unique_ptr<VulkanFrameGenerator> VulkanFrameGenerator::Create(
    VulkanDevice* const vulkan_device, const UISamplers* const ui_samplers) {
  auto generator = std::unique_ptr<VulkanFrameGenerator>(
      new VulkanFrameGenerator(vulkan_device, ui_samplers));
  if (!generator->Initialize()) {
    return nullptr;
  }
  return generator;
}

VulkanFrameGenerator::~VulkanFrameGenerator() {
  const VulkanDevice::Functions& dfn = vulkan_device_->functions();
  const VkDevice device = vulkan_device_->device();

  DestroyResources();

  for (VkPipeline& pipeline : pipelines_) {
    util::DestroyAndNullHandle(dfn.vkDestroyPipeline, device, pipeline);
  }
  util::DestroyAndNullHandle(dfn.vkDestroyDescriptorPool, device,
                             descriptor_pool_);
  util::DestroyAndNullHandle(dfn.vkDestroyPipelineLayout, device,
                             pipeline_layout_);
  util::DestroyAndNullHandle(dfn.vkDestroyDescriptorSetLayout, device,
                             descriptor_set_layout_);
}

bool VulkanFrameGenerator::Initialize() {
  const VulkanDevice::Functions& dfn = vulkan_device_->functions();
  const VkDevice device = vulkan_device_->device();

  // One layout for every pass: three sampled inputs and one storage output. A
  // pass needing fewer inputs points the spare bindings at an image it already
  // uses - cheaper than four nearly identical layouts, and Vulkan requires
  // every binding in a bound set to have been written regardless.
  const VkSampler sampler_linear_clamp =
      ui_samplers_->samplers()[UISamplers::kSamplerIndexLinearClampToEdge];
  const VkSampler immutable_samplers[3] = {
      sampler_linear_clamp, sampler_linear_clamp, sampler_linear_clamp};
  VkDescriptorSetLayoutBinding bindings[4];
  for (uint32_t i = 0; i < 3; ++i) {
    bindings[i].binding = i;
    bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    bindings[i].descriptorCount = 1;
    bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    bindings[i].pImmutableSamplers = &immutable_samplers[i];
  }
  bindings[3].binding = 3;
  bindings[3].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  bindings[3].descriptorCount = 1;
  bindings[3].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  bindings[3].pImmutableSamplers = nullptr;

  VkDescriptorSetLayoutCreateInfo descriptor_set_layout_create_info;
  descriptor_set_layout_create_info.sType =
      VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
  descriptor_set_layout_create_info.pNext = nullptr;
  descriptor_set_layout_create_info.flags = 0;
  descriptor_set_layout_create_info.bindingCount = 4;
  descriptor_set_layout_create_info.pBindings = bindings;
  if (dfn.vkCreateDescriptorSetLayout(
          device, &descriptor_set_layout_create_info, nullptr,
          &descriptor_set_layout_) != VK_SUCCESS) {
    XELOGE("VulkanFrameGenerator: Failed to create the descriptor set layout");
    return false;
  }

  VkPushConstantRange push_constant_range;
  push_constant_range.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
  push_constant_range.offset = 0;
  push_constant_range.size = uint32_t(sizeof(PushConstants));
  VkPipelineLayoutCreateInfo pipeline_layout_create_info;
  pipeline_layout_create_info.sType =
      VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
  pipeline_layout_create_info.pNext = nullptr;
  pipeline_layout_create_info.flags = 0;
  pipeline_layout_create_info.setLayoutCount = 1;
  pipeline_layout_create_info.pSetLayouts = &descriptor_set_layout_;
  pipeline_layout_create_info.pushConstantRangeCount = 1;
  pipeline_layout_create_info.pPushConstantRanges = &push_constant_range;
  if (dfn.vkCreatePipelineLayout(device, &pipeline_layout_create_info, nullptr,
                                 &pipeline_layout_) != VK_SUCCESS) {
    XELOGE("VulkanFrameGenerator: Failed to create the pipeline layout");
    return false;
  }

  VkDescriptorPoolSize pool_sizes[2];
  pool_sizes[0].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
  pool_sizes[0].descriptorCount = kDescriptorSetRingSize * 3;
  pool_sizes[1].type = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  pool_sizes[1].descriptorCount = kDescriptorSetRingSize;
  VkDescriptorPoolCreateInfo descriptor_pool_create_info;
  descriptor_pool_create_info.sType =
      VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
  descriptor_pool_create_info.pNext = nullptr;
  descriptor_pool_create_info.flags = 0;
  descriptor_pool_create_info.maxSets = kDescriptorSetRingSize;
  descriptor_pool_create_info.poolSizeCount = 2;
  descriptor_pool_create_info.pPoolSizes = pool_sizes;
  if (dfn.vkCreateDescriptorPool(device, &descriptor_pool_create_info, nullptr,
                                 &descriptor_pool_) != VK_SUCCESS) {
    XELOGE("VulkanFrameGenerator: Failed to create the descriptor pool");
    return false;
  }

  std::array<VkDescriptorSetLayout, kDescriptorSetRingSize> set_layouts;
  set_layouts.fill(descriptor_set_layout_);
  VkDescriptorSetAllocateInfo descriptor_set_allocate_info;
  descriptor_set_allocate_info.sType =
      VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
  descriptor_set_allocate_info.pNext = nullptr;
  descriptor_set_allocate_info.descriptorPool = descriptor_pool_;
  descriptor_set_allocate_info.descriptorSetCount = kDescriptorSetRingSize;
  descriptor_set_allocate_info.pSetLayouts = set_layouts.data();
  if (dfn.vkAllocateDescriptorSets(device, &descriptor_set_allocate_info,
                                   descriptor_sets_.data()) != VK_SUCCESS) {
    XELOGE("VulkanFrameGenerator: Failed to allocate the descriptor sets");
    return false;
  }

  struct ShaderEntry {
    Pipeline index;
    const uint32_t* code;
    size_t size;
    const char* name;
  };
  const ShaderEntry shaders[] = {
      {kPipelineCopy, frame_gen_copy_cs, sizeof(frame_gen_copy_cs), "copy"},
      {kPipelineLuma, frame_gen_luma_cs, sizeof(frame_gen_luma_cs), "luma"},
      {kPipelineSearch, frame_gen_search_cs, sizeof(frame_gen_search_cs),
       "search"},
      {kPipelineSmooth, frame_gen_smooth_cs, sizeof(frame_gen_smooth_cs),
       "smooth"},
      {kPipelineWarp, frame_gen_warp_cs, sizeof(frame_gen_warp_cs), "warp"},
  };
  for (const ShaderEntry& shader : shaders) {
    pipelines_[shader.index] = util::CreateComputePipeline(
        vulkan_device_, pipeline_layout_, shader.code, shader.size);
    if (pipelines_[shader.index] == VK_NULL_HANDLE) {
      XELOGE("VulkanFrameGenerator: Failed to create the {} pipeline",
             shader.name);
      return false;
    }
  }

  return true;
}

bool VulkanFrameGenerator::CreateImage(Image& image, uint32_t width,
                                       uint32_t height, VkFormat format,
                                       const char* what) {
  width = std::max(width, uint32_t(1));
  height = std::max(height, uint32_t(1));

  VkImageCreateInfo image_create_info;
  image_create_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
  image_create_info.pNext = nullptr;
  image_create_info.flags = 0;
  image_create_info.imageType = VK_IMAGE_TYPE_2D;
  image_create_info.format = format;
  image_create_info.extent.width = width;
  image_create_info.extent.height = height;
  image_create_info.extent.depth = 1;
  image_create_info.mipLevels = 1;
  image_create_info.arrayLayers = 1;
  image_create_info.samples = VK_SAMPLE_COUNT_1_BIT;
  image_create_info.tiling = VK_IMAGE_TILING_OPTIMAL;
  image_create_info.usage =
      VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
  image_create_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  image_create_info.queueFamilyIndexCount = 0;
  image_create_info.pQueueFamilyIndices = nullptr;
  image_create_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
  if (!util::CreateDedicatedAllocationImage(
          vulkan_device_, image_create_info, util::MemoryPurpose::kDeviceLocal,
          image.image, image.memory)) {
    XELOGE("VulkanFrameGenerator: Failed to create the {} image ({}x{})", what,
           width, height);
    return false;
  }

  const VulkanDevice::Functions& dfn = vulkan_device_->functions();
  const VkDevice device = vulkan_device_->device();

  VkImageViewCreateInfo image_view_create_info;
  image_view_create_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
  image_view_create_info.pNext = nullptr;
  image_view_create_info.flags = 0;
  image_view_create_info.image = image.image;
  image_view_create_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
  image_view_create_info.format = format;
  image_view_create_info.components.r = VK_COMPONENT_SWIZZLE_IDENTITY;
  image_view_create_info.components.g = VK_COMPONENT_SWIZZLE_IDENTITY;
  image_view_create_info.components.b = VK_COMPONENT_SWIZZLE_IDENTITY;
  image_view_create_info.components.a = VK_COMPONENT_SWIZZLE_IDENTITY;
  image_view_create_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
  image_view_create_info.subresourceRange.baseMipLevel = 0;
  image_view_create_info.subresourceRange.levelCount = 1;
  image_view_create_info.subresourceRange.baseArrayLayer = 0;
  image_view_create_info.subresourceRange.layerCount = 1;
  if (dfn.vkCreateImageView(device, &image_view_create_info, nullptr,
                            &image.view) != VK_SUCCESS) {
    XELOGE("VulkanFrameGenerator: Failed to create the {} image view", what);
    return false;
  }

  image.width = width;
  image.height = height;
  return true;
}

void VulkanFrameGenerator::DestroyImage(Image& image) {
  const VulkanDevice::Functions& dfn = vulkan_device_->functions();
  const VkDevice device = vulkan_device_->device();
  util::DestroyAndNullHandle(dfn.vkDestroyImageView, device, image.view);
  util::DestroyAndNullHandle(dfn.vkDestroyImage, device, image.image);
  util::DestroyAndNullHandle(dfn.vkFreeMemory, device, image.memory);
  image.width = 0;
  image.height = 0;
}

void VulkanFrameGenerator::DestroyResources() {
  DestroyImage(history_);
  for (Image& image : luma_fine_) {
    DestroyImage(image);
  }
  for (Image& image : luma_coarse_) {
    DestroyImage(image);
  }
  DestroyImage(mv_coarse_);
  DestroyImage(mv_fine_);
  DestroyImage(mv_smooth_);
  DestroyImage(generated_);
  current_width_ = 0;
  current_height_ = 0;
  has_history_ = false;
  needs_initial_transitions_ = false;
  generated_in_read_layout_ = false;
}

bool VulkanFrameGenerator::EnsureResources(uint32_t width, uint32_t height) {
  if (current_width_ == width && current_height_ == height) {
    return !resources_failed_;
  }
  // A size change invalidates everything, the stored history included - the
  // frame before a resize is not one this frame can be interpolated from.
  DestroyResources();
  resources_failed_ = false;

  const uint32_t fine_width = DivideRoundingUp(width, kLumaFineDiv);
  const uint32_t fine_height = DivideRoundingUp(height, kLumaFineDiv);
  const uint32_t coarse_width = DivideRoundingUp(width, kLumaCoarseDiv);
  const uint32_t coarse_height = DivideRoundingUp(height, kLumaCoarseDiv);
  const uint32_t block_width = DivideRoundingUp(width, kBlockSize);
  const uint32_t block_height = DivideRoundingUp(height, kBlockSize);

  bool ok = CreateImage(history_, width, height, kColorFormat, "history");
  ok = CreateImage(generated_, width, height, kColorFormat, "generated") && ok;
  for (uint32_t i = 0; i < 2; ++i) {
    ok = CreateImage(luma_fine_[i], fine_width, fine_height, kLumaFormat,
                     "fine luma") &&
         ok;
    ok = CreateImage(luma_coarse_[i], coarse_width, coarse_height, kLumaFormat,
                     "coarse luma") &&
         ok;
  }
  ok = CreateImage(mv_coarse_, block_width, block_height, kMotionFormat,
                   "coarse motion") &&
       ok;
  ok = CreateImage(mv_fine_, block_width, block_height, kMotionFormat,
                   "fine motion") &&
       ok;
  ok = CreateImage(mv_smooth_, block_width, block_height, kMotionFormat,
                   "smoothed motion") &&
       ok;

  if (!ok) {
    XELOGE(
        "VulkanFrameGenerator: Could not allocate work images for {}x{} - "
        "frame generation disabled",
        width, height);
    DestroyResources();
    resources_failed_ = true;
    return false;
  }

  ++generated_version_;
  current_width_ = width;
  current_height_ = height;
  luma_slot_ = 0;
  needs_initial_transitions_ = true;
  generated_in_read_layout_ = false;
  return true;
}

void VulkanFrameGenerator::RecordInitialTransitions(
    VkCommandBuffer command_buffer) {
  if (!needs_initial_transitions_) {
    return;
  }
  needs_initial_transitions_ = false;

  const Image* const images[] = {
      &history_,        &luma_fine_[0], &luma_fine_[1], &luma_coarse_[0],
      &luma_coarse_[1], &mv_coarse_,    &mv_fine_,      &mv_smooth_,
      &generated_};
  constexpr size_t kImageCount = sizeof(images) / sizeof(images[0]);
  VkImageMemoryBarrier barriers[kImageCount];
  uint32_t barrier_count = 0;
  for (const Image* image : images) {
    if (image->image == VK_NULL_HANDLE) {
      continue;
    }
    VkImageMemoryBarrier& barrier = barriers[barrier_count++];
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.pNext = nullptr;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask =
        VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    // Discarding whatever was in the memory is correct: each of these is fully
    // written by the pass that produces it before anything reads it.
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image->image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
  }
  if (!barrier_count) {
    return;
  }
  vulkan_device_->functions().vkCmdPipelineBarrier(
      command_buffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
      VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, nullptr, 0, nullptr,
      barrier_count, barriers);
  generated_in_read_layout_ = false;
}

void VulkanFrameGenerator::BarrierComputeToCompute(
    VkCommandBuffer command_buffer) {
  // Everything this class owns lives in GENERAL, so an execution and memory
  // dependency is all a pass needs before reading what the last one wrote.
  VkMemoryBarrier memory_barrier;
  memory_barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
  memory_barrier.pNext = nullptr;
  memory_barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
  memory_barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
  vulkan_device_->functions().vkCmdPipelineBarrier(
      command_buffer, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
      VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &memory_barrier, 0, nullptr,
      0, nullptr);
}

void VulkanFrameGenerator::Dispatch(VkCommandBuffer command_buffer,
                                    Pipeline pipeline,
                                    const SampledInput& src0,
                                    const SampledInput& src1,
                                    const SampledInput& src2, const Image& dst,
                                    const PushConstants& push) {
  const VulkanDevice::Functions& dfn = vulkan_device_->functions();
  const VkDevice device = vulkan_device_->device();

  const VkDescriptorSet descriptor_set =
      descriptor_sets_[descriptor_set_next_ % kDescriptorSetRingSize];
  ++descriptor_set_next_;

  const SampledInput* const sources[3] = {&src0, &src1, &src2};
  VkDescriptorImageInfo image_infos[4];
  VkWriteDescriptorSet writes[4];
  for (uint32_t i = 0; i < 3; ++i) {
    image_infos[i].sampler = VK_NULL_HANDLE;  // Immutable in the layout.
    image_infos[i].imageView = sources[i]->view;
    image_infos[i].imageLayout = sources[i]->layout;
    writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writes[i].pNext = nullptr;
    writes[i].dstSet = descriptor_set;
    writes[i].dstBinding = i;
    writes[i].dstArrayElement = 0;
    writes[i].descriptorCount = 1;
    writes[i].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writes[i].pImageInfo = &image_infos[i];
    writes[i].pBufferInfo = nullptr;
    writes[i].pTexelBufferView = nullptr;
  }
  image_infos[3].sampler = VK_NULL_HANDLE;
  image_infos[3].imageView = dst.view;
  image_infos[3].imageLayout = VK_IMAGE_LAYOUT_GENERAL;
  writes[3].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
  writes[3].pNext = nullptr;
  writes[3].dstSet = descriptor_set;
  writes[3].dstBinding = 3;
  writes[3].dstArrayElement = 0;
  writes[3].descriptorCount = 1;
  writes[3].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
  writes[3].pImageInfo = &image_infos[3];
  writes[3].pBufferInfo = nullptr;
  writes[3].pTexelBufferView = nullptr;
  dfn.vkUpdateDescriptorSets(device, 4, writes, 0, nullptr);

  dfn.vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                        pipelines_[pipeline]);
  dfn.vkCmdBindDescriptorSets(command_buffer, VK_PIPELINE_BIND_POINT_COMPUTE,
                              pipeline_layout_, 0, 1, &descriptor_set, 0,
                              nullptr);
  dfn.vkCmdPushConstants(command_buffer, pipeline_layout_,
                         VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(push), &push);
  dfn.vkCmdDispatch(command_buffer, DivideRoundingUp(dst.width, kLocalSize),
                    DivideRoundingUp(dst.height, kLocalSize), 1);
}

void VulkanFrameGenerator::RecordLumaPyramid(VkCommandBuffer command_buffer,
                                             const SampledInput& source,
                                             uint32_t source_width,
                                             uint32_t source_height,
                                             uint32_t slot) {
  PushConstants push = {};
  push.src_texel[0] = 1.0f / float(source_width);
  push.src_texel[1] = 1.0f / float(source_height);
  push.dst_size[0] = float(luma_fine_[slot].width);
  push.dst_size[1] = float(luma_fine_[slot].height);
  push.taps = int32_t(kLumaFineDiv);
  Dispatch(command_buffer, kPipelineLuma, source, source, source,
           luma_fine_[slot], push);
  BarrierComputeToCompute(command_buffer);

  const SampledInput fine{luma_fine_[slot].view, VK_IMAGE_LAYOUT_GENERAL};
  push = PushConstants();
  push.src_texel[0] = 1.0f / float(luma_fine_[slot].width);
  push.src_texel[1] = 1.0f / float(luma_fine_[slot].height);
  push.dst_size[0] = float(luma_coarse_[slot].width);
  push.dst_size[1] = float(luma_coarse_[slot].height);
  push.taps = int32_t(kLumaCoarseDiv / kLumaFineDiv);
  Dispatch(command_buffer, kPipelineLuma, fine, fine, fine, luma_coarse_[slot],
           push);
  BarrierComputeToCompute(command_buffer);
}

bool VulkanFrameGenerator::RecordCaptureOnly(VkCommandBuffer command_buffer,
                                             VkImageView guest_view,
                                             uint32_t width, uint32_t height) {
  if (!EnsureResources(width, height)) {
    return false;
  }
  RecordInitialTransitions(command_buffer);

  const SampledInput guest{guest_view,
                           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};

  PushConstants push = {};
  push.dst_size[0] = float(width);
  push.dst_size[1] = float(height);
  Dispatch(command_buffer, kPipelineCopy, guest, guest, guest, history_, push);
  BarrierComputeToCompute(command_buffer);

  // The luma of what is now the history, so the next frame's search already has
  // both ends of the pyramid.
  RecordLumaPyramid(command_buffer, guest, width, height, luma_slot_);

  has_history_ = true;
  return true;
}

bool VulkanFrameGenerator::RecordGenerateAndCapture(
    VkCommandBuffer command_buffer, VkImageView guest_view, uint32_t width,
    uint32_t height, float t) {
  if (!has_history_ || resources_failed_ || current_width_ != width ||
      current_height_ != height) {
    // Nothing to interpolate from - the caller falls back to presenting the
    // guest image and capturing it as the history.
    return false;
  }
  RecordInitialTransitions(command_buffer);

  const uint32_t prev_slot = luma_slot_;
  const uint32_t cur_slot = luma_slot_ ^ 1;

  const VulkanDevice::Functions& dfn = vulkan_device_->functions();

  const SampledInput guest{guest_view,
                           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
  auto owned = [](const Image& image) {
    return SampledInput{image.view, VK_IMAGE_LAYOUT_GENERAL};
  };

  // The generated image was left in SHADER_READ_ONLY_OPTIMAL for the paint
  // chain; put it back to GENERAL so it can be written again.
  if (generated_in_read_layout_) {
    VkImageMemoryBarrier barrier;
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.pNext = nullptr;
    barrier.srcAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = generated_.image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    dfn.vkCmdPipelineBarrier(command_buffer,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                             VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0,
                             nullptr, 0, nullptr, 1, &barrier);
    generated_in_read_layout_ = false;
  }

  // 1. Luma pyramid of the current guest image. The previous frame's pyramid is
  //    already in the other slot, built when it was captured.
  RecordLumaPyramid(command_buffer, guest, width, height, cur_slot);

  PushConstants push = {};

  // 2. Coarse search, over the 1/16 luma, from a standing start.
  push.src_texel[0] = 1.0f / float(luma_coarse_[cur_slot].width);
  push.src_texel[1] = 1.0f / float(luma_coarse_[cur_slot].height);
  push.dst_size[0] = float(mv_coarse_.width);
  push.dst_size[1] = float(mv_coarse_.height);
  push.px_per_texel[0] = float(kLumaCoarseDiv);
  push.px_per_texel[1] = float(kLumaCoarseDiv);
  push.lambda = 0.004f;
  push.mode = 0;
  push.steps = 4;
  push.use_pred = 0;
  Dispatch(command_buffer, kPipelineSearch, owned(luma_coarse_[prev_slot]),
           owned(luma_coarse_[cur_slot]), owned(mv_coarse_), mv_coarse_, push);
  BarrierComputeToCompute(command_buffer);

  // 3. Refinement, over the 1/4 luma, predicted by the coarse result.
  push.src_texel[0] = 1.0f / float(luma_fine_[cur_slot].width);
  push.src_texel[1] = 1.0f / float(luma_fine_[cur_slot].height);
  push.dst_size[0] = float(mv_fine_.width);
  push.dst_size[1] = float(mv_fine_.height);
  push.px_per_texel[0] = float(kLumaFineDiv);
  push.px_per_texel[1] = float(kLumaFineDiv);
  push.lambda = 0.010f;
  push.mode = 1;
  push.use_pred = 1;
  Dispatch(command_buffer, kPipelineSearch, owned(luma_fine_[prev_slot]),
           owned(luma_fine_[cur_slot]), owned(mv_coarse_), mv_fine_, push);
  BarrierComputeToCompute(command_buffer);

  // 4. Smooth the field.
  push = PushConstants();
  push.src_texel[0] = 1.0f / float(mv_fine_.width);
  push.src_texel[1] = 1.0f / float(mv_fine_.height);
  push.dst_size[0] = float(mv_smooth_.width);
  push.dst_size[1] = float(mv_smooth_.height);
  Dispatch(command_buffer, kPipelineSmooth, owned(mv_fine_), owned(mv_fine_),
           owned(mv_fine_), mv_smooth_, push);
  BarrierComputeToCompute(command_buffer);

  // 5. Warp both ends to the midpoint. The history still holds the PREVIOUS
  //    frame here - it is not overwritten until step 6.
  push = PushConstants();
  push.src_texel[0] = 1.0f / float(width);
  push.src_texel[1] = 1.0f / float(height);
  push.dst_size[0] = float(width);
  push.dst_size[1] = float(height);
  push.t = t;
  Dispatch(command_buffer, kPipelineWarp, owned(history_), guest,
           owned(mv_smooth_), generated_, push);
  BarrierComputeToCompute(command_buffer);

  // 6. The current guest image becomes the history for the next generated
  //    frame. Ordered after the warp by the barrier above, which is why the
  //    warp could still read the old contents. The barrier that follows makes
  //    the write visible to the next submission's warp.
  push = PushConstants();
  push.dst_size[0] = float(width);
  push.dst_size[1] = float(height);
  Dispatch(command_buffer, kPipelineCopy, guest, guest, guest, history_, push);
  BarrierComputeToCompute(command_buffer);

  // 7. Hand the generated frame to the paint chain in the layout its
  //    descriptors declare.
  {
    VkImageMemoryBarrier barrier;
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.pNext = nullptr;
    barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_GENERAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = generated_.image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    dfn.vkCmdPipelineBarrier(command_buffer,
                             VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                             VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0,
                             nullptr, 0, nullptr, 1, &barrier);
    generated_in_read_layout_ = true;
  }

  // The pyramid just built for the current frame becomes the previous one.
  luma_slot_ = cur_slot;
  return true;
}

}  // namespace vulkan
}  // namespace ui
}  // namespace xe
