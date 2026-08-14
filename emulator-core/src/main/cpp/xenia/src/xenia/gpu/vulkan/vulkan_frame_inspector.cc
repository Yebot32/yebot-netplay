/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/gpu/vulkan/vulkan_frame_inspector.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

#include "xenia/base/cvar.h"
#include "xenia/base/filesystem.h"
#include "xenia/base/logging.h"
#include "xenia/base/math.h"
#include "xenia/config.h"
#include "xenia/gpu/vulkan/vulkan_command_processor.h"
#include "xenia/gpu/xenos.h"
#include "xenia/ui/vulkan/vulkan_util.h"

// Header-only, and given internal linkage so it cannot collide with the copy
// trace_dump.cc instantiates - that one is only reachable in the desktop tools,
// but relying on which archive members the linker happens to pull in is not
// worth the risk for a file that costs a few KB.
#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#ifdef __clang__
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#endif
#include "third_party/stb/stb_image_write.h"
#ifdef __clang__
#pragma clang diagnostic pop
#endif

DEFINE_bool(
    frame_inspector, false,
    "Capture every guest render target at every render pass boundary, for a "
    "short run of frames, and write them out as PNGs with an HTML report. This "
    "is the tool for WRONG PIXELS - geometry drawn in the wrong order, "
    "surfaces that should be hidden showing through, anything that flickers - "
    "as opposed to the log-based diagnostics, which can only report what the "
    "guest asked for and not what came out. Depth is captured as well as "
    "colour, rescaled so it is actually readable, and consecutive frames are "
    "diffed automatically so temporal artifacts show up without capturing "
    "screenshots by hand. Must be set BEFORE launch: it adds a transfer-source "
    "usage flag when render targets are created, and render targets are "
    "cached, so enabling it mid-run captures nothing. Costs nothing when off.",
    "Vulkan");

DEFINE_int32(
    frame_inspector_first_frame, 0,
    "Guest frame to start the frame_inspector capture at. On a console that "
    "boots a launcher title before the game, an early capture only ever sees "
    "the launcher, so set this past the point the artifact is actually on "
    "screen - the f: stamp on each log line is the frame number.",
    "Vulkan");

DEFINE_int32(
    frame_inspector_frames, 2,
    "How many consecutive guest frames frame_inspector captures. Two is the "
    "minimum that produces a frame-to-frame diff, which is the point of the "
    "tool for anything that flickers; more frames catch an artifact that only "
    "appears intermittently, at a proportional cost in time and storage. Hold "
    "the camera still while capturing, or every diff is dominated by the view "
    "legitimately changing.",
    "Vulkan");

DEFINE_int32(
    frame_inspector_budget_mb, 192,
    "Memory ceiling, in MB, for one captured frame's render target readback. A "
    "render target is copied only if it fits in what is left; the report says "
    "so when one is dropped, rather than silently omitting it.",
    "Vulkan");

DEFINE_string(
    frame_inspector_path, "",
    "Directory frame_inspector writes to. Defaults to an 'inspect' directory "
    "beside the log file, which is the one directory already known to be "
    "writable and already known to the person collecting the results.",
    "Vulkan");

DEFINE_bool(
    frame_inspector_log_extents, false,
    "Log each captured pass's host render target extent against the extent its "
    "draws actually covered. Only useful for working out how much of a capture "
    "is empty EDRAM below the frame.",
    "Vulkan");

DECLARE_path(log_file);

namespace xe {
namespace gpu {
namespace vulkan {

namespace {

// Depth as stored by the host, decoded to a float in 0...1.
float DecodeDepth(const uint8_t* pixel, VkFormat format) {
  if (format == VK_FORMAT_D24_UNORM_S8_UINT) {
    // The depth aspect of a packed depth-stencil image copies out as 32 bits
    // per texel with the low 24 holding depth.
    uint32_t bits;
    std::memcpy(&bits, pixel, sizeof(bits));
    return float(bits & 0xFFFFFFu) / float(0xFFFFFFu);
  }
  float value;
  std::memcpy(&value, pixel, sizeof(value));
  return value;
}

// Both host depth formats in use are 32 bits per texel on the depth aspect:
// D32_SFLOAT_S8_UINT copies out as a float, and the depth aspect of
// D24_UNORM_S8_UINT copies out as 32 bits with the low 24 used.
constexpr uint32_t kDepthTexelSize = 4;

uint8_t ToByte(float unit_value) {
  return uint8_t(std::lround(
      std::clamp(unit_value, 0.0f, 1.0f) * 255.0f));
}

// Half-float, for the 16-bit colour formats.
float DecodeHalf(uint16_t bits) {
  const uint32_t sign = uint32_t(bits & 0x8000u) << 16;
  uint32_t exponent = (bits >> 10) & 0x1Fu;
  uint32_t mantissa = bits & 0x3FFu;
  if (exponent == 0) {
    if (mantissa == 0) {
      float result;
      std::memcpy(&result, &sign, sizeof(result));
      return result;
    }
    // Subnormal - normalize it.
    while (!(mantissa & 0x400u)) {
      mantissa <<= 1;
      --exponent;
    }
    ++exponent;
    mantissa &= 0x3FFu;
  } else if (exponent == 0x1Fu) {
    const uint32_t bits32 = sign | 0x7F800000u | (mantissa << 13);
    float result;
    std::memcpy(&result, &bits32, sizeof(result));
    return result;
  }
  const uint32_t bits32 =
      sign | ((exponent + 112u) << 23) | (mantissa << 13);
  float result;
  std::memcpy(&result, &bits32, sizeof(result));
  return result;
}

// Bytes per texel of a colour render target as copied out.
uint32_t ColorTexelSize(VkFormat format) {
  switch (format) {
    case VK_FORMAT_R8G8B8A8_UNORM:
    case VK_FORMAT_R8G8B8A8_SRGB:
    case VK_FORMAT_B8G8R8A8_UNORM:
    case VK_FORMAT_A2B10G10R10_UNORM_PACK32:
    case VK_FORMAT_A2R10G10B10_UNORM_PACK32:
    case VK_FORMAT_B10G11R11_UFLOAT_PACK32:
    case VK_FORMAT_R16G16_UNORM:
    case VK_FORMAT_R16G16_SNORM:
    case VK_FORMAT_R16G16_SFLOAT:
    case VK_FORMAT_R32_SFLOAT:
      return 4;
    case VK_FORMAT_R16G16B16A16_UNORM:
    case VK_FORMAT_R16G16B16A16_SNORM:
    case VK_FORMAT_R16G16B16A16_SFLOAT:
    case VK_FORMAT_R32G32_SFLOAT:
      return 8;
    case VK_FORMAT_R32G32B32A32_SFLOAT:
      return 16;
    default:
      return 0;
  }
}

// Decodes one colour texel to RGBA8. Float formats are tone-mapped only by
// clamping: the point is to see geometry and ordering, and a curve applied here
// would be one more thing to disbelieve when the image looks wrong.
void DecodeColor(const uint8_t* pixel, VkFormat format, uint8_t* rgba_out) {
  auto unpack32 = [pixel]() {
    uint32_t bits;
    std::memcpy(&bits, pixel, sizeof(bits));
    return bits;
  };
  switch (format) {
    case VK_FORMAT_R8G8B8A8_UNORM:
    case VK_FORMAT_R8G8B8A8_SRGB:
      std::memcpy(rgba_out, pixel, 4);
      break;
    case VK_FORMAT_B8G8R8A8_UNORM:
      rgba_out[0] = pixel[2];
      rgba_out[1] = pixel[1];
      rgba_out[2] = pixel[0];
      rgba_out[3] = pixel[3];
      break;
    case VK_FORMAT_A2B10G10R10_UNORM_PACK32: {
      const uint32_t bits = unpack32();
      rgba_out[0] = ToByte(float(bits & 0x3FFu) / 1023.0f);
      rgba_out[1] = ToByte(float((bits >> 10) & 0x3FFu) / 1023.0f);
      rgba_out[2] = ToByte(float((bits >> 20) & 0x3FFu) / 1023.0f);
      rgba_out[3] = ToByte(float((bits >> 30) & 0x3u) / 3.0f);
      break;
    }
    case VK_FORMAT_A2R10G10B10_UNORM_PACK32: {
      const uint32_t bits = unpack32();
      rgba_out[2] = ToByte(float(bits & 0x3FFu) / 1023.0f);
      rgba_out[1] = ToByte(float((bits >> 10) & 0x3FFu) / 1023.0f);
      rgba_out[0] = ToByte(float((bits >> 20) & 0x3FFu) / 1023.0f);
      rgba_out[3] = ToByte(float((bits >> 30) & 0x3u) / 3.0f);
      break;
    }
    case VK_FORMAT_B10G11R11_UFLOAT_PACK32: {
      // 11/11/10 unsigned floats; approximated closely enough for inspection by
      // widening each to a half and reusing the half decoder.
      const uint32_t bits = unpack32();
      const float r = DecodeHalf(uint16_t((bits & 0x7FFu) << 4));
      const float g = DecodeHalf(uint16_t(((bits >> 11) & 0x7FFu) << 4));
      const float b = DecodeHalf(uint16_t(((bits >> 22) & 0x3FFu) << 5));
      rgba_out[0] = ToByte(r);
      rgba_out[1] = ToByte(g);
      rgba_out[2] = ToByte(b);
      rgba_out[3] = 255;
      break;
    }
    case VK_FORMAT_R16G16_UNORM:
    case VK_FORMAT_R16G16_SNORM:
    case VK_FORMAT_R16G16_SFLOAT:
    case VK_FORMAT_R16G16B16A16_UNORM:
    case VK_FORMAT_R16G16B16A16_SNORM:
    case VK_FORMAT_R16G16B16A16_SFLOAT: {
      const bool has_alpha = format == VK_FORMAT_R16G16B16A16_UNORM ||
                             format == VK_FORMAT_R16G16B16A16_SNORM ||
                             format == VK_FORMAT_R16G16B16A16_SFLOAT;
      const bool is_float = format == VK_FORMAT_R16G16_SFLOAT ||
                            format == VK_FORMAT_R16G16B16A16_SFLOAT;
      const bool is_snorm = format == VK_FORMAT_R16G16_SNORM ||
                            format == VK_FORMAT_R16G16B16A16_SNORM;
      const uint32_t component_count = has_alpha ? 4 : 2;
      float components[4] = {0.0f, 0.0f, 0.0f, 1.0f};
      for (uint32_t i = 0; i < component_count; ++i) {
        uint16_t bits;
        std::memcpy(&bits, pixel + i * sizeof(uint16_t), sizeof(bits));
        if (is_float) {
          components[i] = DecodeHalf(bits);
        } else if (is_snorm) {
          components[i] = float(int16_t(bits)) / 32767.0f * 0.5f + 0.5f;
        } else {
          components[i] = float(bits) / 65535.0f;
        }
      }
      for (uint32_t i = 0; i < 4; ++i) {
        rgba_out[i] = ToByte(components[i]);
      }
      break;
    }
    case VK_FORMAT_R32_SFLOAT:
    case VK_FORMAT_R32G32_SFLOAT:
    case VK_FORMAT_R32G32B32A32_SFLOAT: {
      const uint32_t component_count = format == VK_FORMAT_R32_SFLOAT     ? 1
                                       : format == VK_FORMAT_R32G32_SFLOAT ? 2
                                                                           : 4;
      float components[4] = {0.0f, 0.0f, 0.0f, 1.0f};
      for (uint32_t i = 0; i < component_count; ++i) {
        std::memcpy(&components[i], pixel + i * sizeof(float), sizeof(float));
      }
      for (uint32_t i = 0; i < 4; ++i) {
        rgba_out[i] = ToByte(components[i]);
      }
      break;
    }
    default:
      rgba_out[0] = rgba_out[1] = rgba_out[2] = 0;
      rgba_out[3] = 255;
      break;
  }
}

const char* MsaaName(xenos::MsaaSamples samples) {
  switch (samples) {
    case xenos::MsaaSamples::k1X:
      return "1x";
    case xenos::MsaaSamples::k2X:
      return "2x";
    case xenos::MsaaSamples::k4X:
      return "4x";
    default:
      return "?";
  }
}

bool WritePng(const std::filesystem::path& path, uint32_t width,
              uint32_t height, const uint8_t* rgba) {
  // stb takes a narrow path; on Android the output tree is ASCII, and a failure
  // here is reported rather than being allowed to look like an empty capture.
  const std::string narrow_path = xe::path_to_utf8(path);
  return stbi_write_png(narrow_path.c_str(), int(width), int(height), 4, rgba,
                        int(width) * 4) != 0;
}

}  // namespace

VulkanFrameInspector::VulkanFrameInspector(
    VulkanCommandProcessor& command_processor)
    : command_processor_(command_processor) {
  if (!cvars::frame_inspector) {
    return;
  }
  if (!cvars::frame_inspector_path.empty()) {
    output_root_ = xe::to_path(cvars::frame_inspector_path);
  } else if (!config::config_folder.empty()) {
    // The config folder, not the executable folder: on Android the executable
    // lives in a read-only install directory, while this is the app's own
    // storage - already writable, already where the log is, and already the
    // directory anyone collecting results is pulling from.
    output_root_ = config::config_folder / "inspect";
  } else if (!cvars::log_file.empty()) {
    output_root_ = cvars::log_file.parent_path() / "inspect";
  } else {
    output_root_ = xe::filesystem::GetExecutableFolder() / "inspect";
  }
  // Each title gets its own directory. The app boots a launcher title and then
  // relaunches into the game, which builds a second command processor and
  // restarts the guest frame count from zero - so both titles hit the same
  // requested frame number and, sharing one directory, the second would
  // silently overwrite the first. Which one is the game is then obvious from
  // the run index in the log line below.
  static uint32_t run_index = 0;
  output_root_ /= xe::to_path(fmt::format("run{:02}", run_index++));
  std::error_code error_code;
  std::filesystem::create_directories(output_root_, error_code);
  active_ = true;
  XELOGI(
      "FrameInspector: armed, capturing {} frame(s) from guest frame {} into "
      "{}",
      std::max(1, cvars::frame_inspector_frames),
      cvars::frame_inspector_first_frame, xe::path_to_utf8(output_root_));
}

VulkanFrameInspector::~VulkanFrameInspector() { DestroyReadbackBuffer(); }

void VulkanFrameInspector::DestroyReadbackBuffer() {
  if (readback_buffer_ == VK_NULL_HANDLE && readback_memory_ == VK_NULL_HANDLE) {
    return;
  }
  const ui::vulkan::VulkanDevice* const vulkan_device =
      command_processor_.GetVulkanDevice();
  const ui::vulkan::VulkanDevice::Functions& dfn = vulkan_device->functions();
  const VkDevice device = vulkan_device->device();
  if (readback_buffer_ != VK_NULL_HANDLE) {
    dfn.vkDestroyBuffer(device, readback_buffer_, nullptr);
    readback_buffer_ = VK_NULL_HANDLE;
  }
  if (readback_memory_ != VK_NULL_HANDLE) {
    dfn.vkFreeMemory(device, readback_memory_, nullptr);
    readback_memory_ = VK_NULL_HANDLE;
  }
  readback_capacity_ = 0;
}

bool VulkanFrameInspector::EnsureReadbackBuffer(VkDeviceSize size) {
  if (readback_capacity_ >= size) {
    return true;
  }
  DestroyReadbackBuffer();

  const ui::vulkan::VulkanDevice* const vulkan_device =
      command_processor_.GetVulkanDevice();
  const ui::vulkan::VulkanDevice::Functions& dfn = vulkan_device->functions();
  const VkDevice device = vulkan_device->device();

  VkBufferCreateInfo buffer_create_info;
  buffer_create_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
  buffer_create_info.pNext = nullptr;
  buffer_create_info.flags = 0;
  buffer_create_info.size = size;
  buffer_create_info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
  buffer_create_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  buffer_create_info.queueFamilyIndexCount = 0;
  buffer_create_info.pQueueFamilyIndices = nullptr;
  if (dfn.vkCreateBuffer(device, &buffer_create_info, nullptr,
                         &readback_buffer_) != VK_SUCCESS) {
    XELOGE("FrameInspector: failed to create a {} byte readback buffer", size);
    readback_buffer_ = VK_NULL_HANDLE;
    return false;
  }

  VkMemoryRequirements memory_requirements;
  dfn.vkGetBufferMemoryRequirements(device, readback_buffer_,
                                    &memory_requirements);
  VkMemoryAllocateInfo allocate_info;
  allocate_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
  allocate_info.pNext = nullptr;
  allocate_info.allocationSize = memory_requirements.size;
  allocate_info.memoryTypeIndex = ui::vulkan::util::ChooseMemoryType(
      vulkan_device->memory_types(), memory_requirements.memoryTypeBits,
      ui::vulkan::util::MemoryPurpose::kReadback);
  if (allocate_info.memoryTypeIndex == UINT32_MAX ||
      dfn.vkAllocateMemory(device, &allocate_info, nullptr,
                           &readback_memory_) != VK_SUCCESS) {
    XELOGE("FrameInspector: failed to allocate {} bytes of readback memory",
           memory_requirements.size);
    readback_memory_ = VK_NULL_HANDLE;
    DestroyReadbackBuffer();
    return false;
  }
  if (dfn.vkBindBufferMemory(device, readback_buffer_, readback_memory_, 0) !=
      VK_SUCCESS) {
    XELOGE("FrameInspector: failed to bind readback buffer memory");
    DestroyReadbackBuffer();
    return false;
  }
  readback_capacity_ = size;
  return true;
}

void VulkanFrameInspector::OnGuestFrameEnd(uint64_t frame_index) {
  if (!active_) {
    return;
  }
  if (capturing_) {
    FinishCaptureFrame();
    ++frames_captured_;
    capturing_ = false;
    if (frames_captured_ >= uint64_t(std::max(1, cvars::frame_inspector_frames))) {
      WriteReport();
      DestroyReadbackBuffer();
      previous_images_.clear();
      active_ = false;
      XELOGI("FrameInspector: capture complete, {} frame(s) written to {}",
             frames_captured_, xe::path_to_utf8(output_root_));
      return;
    }
  }
  if (frame_index >= uint64_t(std::max(0, cvars::frame_inspector_first_frame))) {
    BeginCaptureFrame(frame_index);
  }
}

void VulkanFrameInspector::BeginCaptureFrame(uint64_t frame_index) {
  const VkDeviceSize budget = VkDeviceSize(
      std::max(1, cvars::frame_inspector_budget_mb)) * 1024ull * 1024ull;
  if (!EnsureReadbackBuffer(budget)) {
    XELOGE("FrameInspector: no readback buffer, giving up on the capture");
    active_ = false;
    return;
  }
  // Arming happens as one frame ends, so what gets captured is the next one.
  // Labelling by the frame that armed it would put every image one frame off
  // the f: stamps in the log, which is the only way to line a capture up
  // against anything else that was recorded.
  frame_index += 1;
  if (!frames_captured_) {
    capture_start_frame_ = frame_index;
  }
  current_frame_index_ = frame_index;
  frame_directory_ =
      output_root_ / xe::to_path(fmt::format("frame_{:07d}", frame_index));
  std::error_code error_code;
  std::filesystem::create_directories(frame_directory_, error_code);

  readback_used_ = 0;
  pass_index_ = 0;
  captures_.clear();
  passes_.clear();
  current_images_.clear();
  capturing_ = true;
}

void VulkanFrameInspector::RecordDraw(uint64_t vertex_shader_hash,
                                      uint64_t pixel_shader_hash) {
  if (!capturing_) {
    return;
  }
  if (passes_.empty() || passes_.back().pass_index != pass_index_) {
    PassRecord record;
    record.pass_index = pass_index_;
    record.pass_key = VulkanRenderTargetCache::RenderPassKey();
    record.width = 0;
    record.height = 0;
    passes_.push_back(std::move(record));
  }
  passes_.back().draws.emplace_back(vertex_shader_hash, pixel_shader_hash);
}

void VulkanFrameInspector::CapturePass() {
  if (!capturing_) {
    return;
  }
  VulkanRenderTargetCache& render_target_cache =
      *command_processor_.render_target_cache_;
  VulkanRenderTargetCache::InspectorAttachment
      attachments[1 + xenos::kMaxColorRenderTargets];
  const uint32_t attachment_count =
      render_target_cache.GetLastUpdateInspectorAttachments(attachments);

  const VulkanRenderTargetCache::Framebuffer* const framebuffer =
      render_target_cache.last_update_framebuffer();
  if (!attachment_count || !framebuffer) {
    // A pass with no guest render targets - a transfer or resolve pass of our
    // own. Nothing to show, and counting it would misalign the pass indices
    // against the draws that were recorded into them.
    return;
  }

  // A host render target spans the whole EDRAM range for its pitch, so the
  // framebuffer extent runs to a couple of thousand rows while the guest is
  // drawing a 720-row frame into the top of it. Capturing all of it is not just
  // wasteful: the empty remainder is depth 0, which drags the minimum of every
  // depth image down to 0 and flattens the contrast stretch that is the whole
  // reason for writing one. So the capture is cropped to the region the pass's
  // draws actually touched, falling back to the full extent when a pass
  // recorded nothing for it to measure.
  // Cropping to the pass's drawn extent was tried and reverted: it measured 640
  // wide on a 1280-wide target and cut the frame in half. The drawn extent is
  // the union of the scissors, and a pass whose draws are scissored to part of
  // the target legitimately reports less than the target's width - so it is not
  // a safe crop, and a capture that quietly discards half the picture is worse
  // than one that includes empty EDRAM. Capturing the full extent is always
  // truthful; the height is dealt with when the depth range is computed.
  const uint32_t width = framebuffer->host_extent.width;
  const uint32_t height = framebuffer->host_extent.height;
  if (cvars::frame_inspector_log_extents) {
    XELOGI(
        "FrameInspector: pass {} host extent {}x{}, drawn extent {}x{}",
        pass_index_, width, height,
        command_processor_.deferred_command_buffer().pass_drawn_width(),
        command_processor_.deferred_command_buffer().pass_drawn_height());
  }

  if (passes_.empty() || passes_.back().pass_index != pass_index_) {
    PassRecord record;
    record.pass_index = pass_index_;
    passes_.push_back(std::move(record));
  }
  PassRecord& pass_record = passes_.back();
  pass_record.pass_key = render_target_cache.last_update_render_pass_key();
  pass_record.width = width;
  pass_record.height = height;

  for (uint32_t i = 0; i < 1 + xenos::kMaxColorRenderTargets; ++i) {
    const VulkanRenderTargetCache::InspectorAttachment& attachment =
        attachments[i];
    if (attachment.image == VK_NULL_HANDLE) {
      continue;
    }
    std::string reason;
    if (!CaptureRenderTarget(attachment, pass_index_,
                             i == 0 ? -1 : int32_t(i - 1), width, height,
                             reason)) {
      if (!pass_record.skipped_reason.empty()) {
        pass_record.skipped_reason += "; ";
      }
      pass_record.skipped_reason += reason;
    }
  }

  ++pass_index_;
}

bool VulkanFrameInspector::CaptureRenderTarget(
    const VulkanRenderTargetCache::InspectorAttachment& attachment,
    uint32_t pass_index, int32_t attachment_index, uint32_t width,
    uint32_t height, std::string& reason_out) {
  const bool is_depth = attachment.is_depth;
  const char* const label = is_depth ? "depth" : "color";

  if (attachment.msaa_samples != xenos::MsaaSamples::k1X) {
    // A multisampled image cannot be copied to a buffer; resolving one here
    // would mean inventing a resolve the guest did not ask for, and showing the
    // result as if it were the attachment.
    reason_out = fmt::format("{}{}: {} MSAA, not copyable", label,
                             attachment_index >= 0 ? std::to_string(
                                 attachment_index) : std::string(),
                             MsaaName(attachment.msaa_samples));
    return false;
  }

  const uint32_t texel_size =
      is_depth ? kDepthTexelSize : ColorTexelSize(attachment.format);
  if (!texel_size) {
    reason_out = fmt::format("{}{}: unhandled format {}", label,
                             attachment_index >= 0 ? std::to_string(
                                 attachment_index) : std::string(),
                             uint32_t(attachment.format));
    return false;
  }

  const VkDeviceSize size =
      VkDeviceSize(width) * VkDeviceSize(height) * texel_size;
  // vkCmdCopyImageToBuffer requires the offset to be a multiple of the texel
  // size, and of 4.
  const VkDeviceSize alignment = std::max<VkDeviceSize>(texel_size, 4);
  const VkDeviceSize offset = xe::align(readback_used_, alignment);
  if (offset + size > readback_capacity_) {
    reason_out = fmt::format("{}{}: over the {} MB budget", label,
                             attachment_index >= 0 ? std::to_string(
                                 attachment_index) : std::string(),
                             cvars::frame_inspector_budget_mb);
    return false;
  }

  VkImageSubresourceRange subresource_range;
  subresource_range.aspectMask = is_depth ? VK_IMAGE_ASPECT_DEPTH_BIT
                                          : VK_IMAGE_ASPECT_COLOR_BIT;
  subresource_range.baseMipLevel = 0;
  subresource_range.levelCount = 1;
  subresource_range.baseArrayLayer = 0;
  subresource_range.layerCount = 1;

  const VkPipelineStageFlags draw_stage_mask =
      is_depth ? (VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT |
                  VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT)
               : VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
  const VkAccessFlags draw_access_mask =
      is_depth ? (VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                  VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT)
               : (VK_ACCESS_COLOR_ATTACHMENT_READ_BIT |
                  VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT);

  // Into a transfer source, copy, then straight back into the layout the render
  // target cache still believes the image is in - so its own tracking stays
  // correct and nothing downstream has to know a capture happened.
  command_processor_.PushImageMemoryBarrier(
      attachment.image, subresource_range, draw_stage_mask,
      VK_PIPELINE_STAGE_TRANSFER_BIT, draw_access_mask,
      VK_ACCESS_TRANSFER_READ_BIT, attachment.layout,
      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);
  // Never forcing the render pass to end: everything here runs from
  // EndRenderPass, after the pass has already closed.
  command_processor_.SubmitBarriers(false);

  VkBufferImageCopy region;
  region.bufferOffset = offset;
  region.bufferRowLength = 0;
  region.bufferImageHeight = 0;
  region.imageSubresource.aspectMask = subresource_range.aspectMask;
  region.imageSubresource.mipLevel = 0;
  region.imageSubresource.baseArrayLayer = 0;
  region.imageSubresource.layerCount = 1;
  region.imageOffset.x = 0;
  region.imageOffset.y = 0;
  region.imageOffset.z = 0;
  region.imageExtent.width = width;
  region.imageExtent.height = height;
  region.imageExtent.depth = 1;
  command_processor_.deferred_command_buffer().CmdVkCopyImageToBuffer(
      attachment.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, readback_buffer_,
      1, &region);

  command_processor_.PushImageMemoryBarrier(
      attachment.image, subresource_range, VK_PIPELINE_STAGE_TRANSFER_BIT,
      draw_stage_mask, VK_ACCESS_TRANSFER_READ_BIT, draw_access_mask,
      VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, attachment.layout);

  Capture capture;
  capture.pass_index = pass_index;
  capture.attachment = attachment_index;
  capture.base_tiles = attachment.base_tiles;
  capture.pitch_tiles_at_32bpp = attachment.pitch_tiles_at_32bpp;
  capture.resource_format = attachment.resource_format;
  capture.format = attachment.format;
  capture.width = width;
  capture.height = height;
  capture.buffer_offset = offset;
  capture.buffer_size = size;
  captures_.push_back(capture);
  readback_used_ = offset + size;
  return true;
}

void VulkanFrameInspector::FinishCaptureFrame() {
  if (captures_.empty()) {
    XELOGW("FrameInspector: frame {} produced no captures",
           current_frame_index_);
    return;
  }

  // Make the copies host-visible and drain, the same way the resolve readback
  // path does. This stalls hard, which is fine - it happens for a handful of
  // frames and the alternative is reading a buffer the GPU is still writing.
  command_processor_.PushBufferMemoryBarrier(
      readback_buffer_, 0, VK_WHOLE_SIZE, VK_PIPELINE_STAGE_TRANSFER_BIT,
      VK_PIPELINE_STAGE_HOST_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
      VK_ACCESS_HOST_READ_BIT, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED,
      false);
  // Unlike the per-pass copies, this runs at the frame boundary, where a render
  // pass may still be open - it has to be closed before the queue can drain.
  command_processor_.SubmitBarriers(true);
  if (!command_processor_.AwaitAllQueueOperationsCompletion()) {
    XELOGE("FrameInspector: drain failed, frame {} discarded",
           current_frame_index_);
    return;
  }

  const ui::vulkan::VulkanDevice* const vulkan_device =
      command_processor_.GetVulkanDevice();
  const ui::vulkan::VulkanDevice::Functions& dfn = vulkan_device->functions();
  const VkDevice device = vulkan_device->device();

  void* mapping = nullptr;
  if (dfn.vkMapMemory(device, readback_memory_, 0, VK_WHOLE_SIZE, 0,
                      &mapping) != VK_SUCCESS) {
    XELOGE("FrameInspector: failed to map the readback buffer");
    return;
  }
  VkMappedMemoryRange invalidate_range;
  invalidate_range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
  invalidate_range.pNext = nullptr;
  invalidate_range.memory = readback_memory_;
  invalidate_range.offset = 0;
  invalidate_range.size = VK_WHOLE_SIZE;
  dfn.vkInvalidateMappedMemoryRanges(device, 1, &invalidate_range);

  report_body_ += fmt::format(
      "<h2 id=\"f{0}\">Guest frame {0}</h2>\n", current_frame_index_);

  uint32_t reported_pass = UINT32_MAX;
  for (const Capture& capture : captures_) {
    if (capture.pass_index != reported_pass) {
      reported_pass = capture.pass_index;
      const PassRecord* pass_record = nullptr;
      for (const PassRecord& candidate : passes_) {
        if (candidate.pass_index == capture.pass_index) {
          pass_record = &candidate;
          break;
        }
      }
      report_body_ += fmt::format("<h3>Pass {}</h3>\n", capture.pass_index);
      if (pass_record) {
        report_body_ += fmt::format(
            "<p class=\"meta\">{}x{}, {} MSAA, {} draw(s)</p>\n",
            pass_record->width, pass_record->height,
            MsaaName(pass_record->pass_key.msaa_samples),
            pass_record->draws.size());
        if (!pass_record->skipped_reason.empty()) {
          report_body_ += fmt::format("<p class=\"skip\">Not captured: {}</p>\n",
                                      pass_record->skipped_reason);
        }
        if (!pass_record->draws.empty()) {
          report_body_ += "<details><summary>draws</summary><pre>";
          uint32_t draw_index = 0;
          for (const auto& draw : pass_record->draws) {
            report_body_ +=
                fmt::format("{:3}  VS {:016X}  PS {:016X}\n", draw_index++,
                            draw.first, draw.second);
          }
          report_body_ += "</pre></details>\n";
        }
      }
      report_body_ += "<div class=\"row\">\n";
    }
    report_body_ += WriteCapture(capture, static_cast<const uint8_t*>(mapping));
  }
  report_body_ += "</div>\n";

  dfn.vkUnmapMemory(device, readback_memory_);

  previous_images_ = std::move(current_images_);
  current_images_.clear();
}

std::string VulkanFrameInspector::WriteCapture(const Capture& capture,
                                               const uint8_t* data) {
  const bool is_depth = capture.attachment < 0;
  const uint32_t pixel_count = capture.width * capture.height;
  const uint8_t* const source = data + capture.buffer_offset;
  const std::string stem =
      is_depth ? fmt::format("pass{:03}_depth", capture.pass_index)
               : fmt::format("pass{:03}_color{}", capture.pass_index,
                             capture.attachment);

  std::string html = "<figure>\n";
  html += fmt::format(
      "<figcaption>{} &mdash; EDRAM tile {}, pitch {}, format {}</figcaption>\n",
      is_depth ? "depth" : fmt::format("color{}", capture.attachment),
      capture.base_tiles, capture.pitch_tiles_at_32bpp,
      capture.resource_format);

  PreviousImage image;
  image.pass_index = capture.pass_index;
  image.attachment = capture.attachment;
  image.width = capture.width;
  image.height = capture.height;
  image.rgba.resize(size_t(pixel_count) * 4);

  if (is_depth) {
    const uint32_t texel_size = kDepthTexelSize;
    image.depth.resize(pixel_count);
    float min_depth = std::numeric_limits<float>::infinity();
    float max_depth = -std::numeric_limits<float>::infinity();
    // A host render target covers the whole EDRAM range for its pitch, so most
    // of what is captured is untouched EDRAM below the frame, sitting at
    // exactly 0. Letting that set the minimum pins the range at 0...1 and
    // flattens the contrast stretch into the same useless near-white image the
    // unstretched one already is. Exact zeros are therefore left out of the
    // RANGE - they are still drawn in the image, so nothing is hidden, and a
    // real depth of exactly 0 is the near clip plane, which is not what the
    // stretch is there to resolve.
    uint32_t ranged_pixels = 0;
    for (uint32_t i = 0; i < pixel_count; ++i) {
      const float depth = DecodeDepth(source + size_t(i) * texel_size,
                                      capture.format);
      image.depth[i] = depth;
      if (depth != 0.0f) {
        min_depth = std::min(min_depth, depth);
        max_depth = std::max(max_depth, depth);
        ++ranged_pixels;
      }
    }
    if (!ranged_pixels) {
      min_depth = 0.0f;
      max_depth = 0.0f;
    }
    // Literal depth, for reference.
    for (uint32_t i = 0; i < pixel_count; ++i) {
      const uint8_t value = ToByte(image.depth[i]);
      image.rgba[size_t(i) * 4 + 0] = value;
      image.rgba[size_t(i) * 4 + 1] = value;
      image.rgba[size_t(i) * 4 + 2] = value;
      image.rgba[size_t(i) * 4 + 3] = 255;
    }
    WritePng(frame_directory_ / xe::to_path(stem + ".png"), capture.width,
             capture.height, image.rgba.data());
    html += fmt::format("<img src=\"{}.png\" title=\"depth as stored\">\n",
                        stem);

    // Contrast-stretched over the range actually present. A far plane sits in a
    // sliver at the top of the depth range, so the literal image above is a
    // white rectangle and this is the one worth looking at.
    const float span = max_depth - min_depth;
    std::vector<uint8_t> stretched(size_t(pixel_count) * 4);
    for (uint32_t i = 0; i < pixel_count; ++i) {
      const uint8_t value =
          span > 0.0f ? ToByte((image.depth[i] - min_depth) / span) : 0;
      stretched[size_t(i) * 4 + 0] = value;
      stretched[size_t(i) * 4 + 1] = value;
      stretched[size_t(i) * 4 + 2] = value;
      stretched[size_t(i) * 4 + 3] = 255;
    }
    WritePng(frame_directory_ / xe::to_path(stem + "_stretched.png"),
             capture.width, capture.height, stretched.data());
    html += fmt::format(
        "<img src=\"{}_stretched.png\" title=\"depth stretched over "
        "{:.6f}...{:.6f}\">\n",
        stem, min_depth, max_depth);

    // What the guest's own 20e4 float24 format can represent, subtracted from
    // what is actually stored, amplified hard. Where this is not black, the
    // host is holding depth the guest format cannot round-trip - which is what
    // an EDRAM round trip has to survive.
    std::vector<uint8_t> residual(size_t(pixel_count) * 4);
    double residual_total = 0.0;
    uint32_t residual_pixels = 0;
    for (uint32_t i = 0; i < pixel_count; ++i) {
      const float stored = image.depth[i];
      const float quantised =
          xenos::Float20e4To32(xenos::Float32To20e4(stored, false));
      const float difference = std::fabs(stored - quantised);
      if (difference > 0.0f) {
        ++residual_pixels;
        residual_total += difference;
      }
      // Scaled so a difference of one part in 2^20 - the finest step the guest
      // format has anywhere - is plainly visible rather than a rounding blip.
      const uint8_t value = ToByte(difference * float(1 << 20));
      residual[size_t(i) * 4 + 0] = value;
      residual[size_t(i) * 4 + 1] = value;
      residual[size_t(i) * 4 + 2] = value;
      residual[size_t(i) * 4 + 3] = 255;
    }
    WritePng(frame_directory_ / xe::to_path(stem + "_20e4residual.png"),
             capture.width, capture.height, residual.data());
    html += fmt::format(
        "<img src=\"{}_20e4residual.png\" title=\"20e4 residual\">\n", stem);
    html += fmt::format(
        "<p class=\"meta\">depth {:.6f}...{:.6f}; {} px ({:.2f}%) do not "
        "round-trip through 20e4, mean error {:.3e}</p>\n",
        min_depth, max_depth, residual_pixels,
        100.0 * double(residual_pixels) / double(std::max(1u, pixel_count)),
        residual_pixels ? residual_total / double(residual_pixels) : 0.0);
  } else {
    const uint32_t texel_size = ColorTexelSize(capture.format);
    for (uint32_t i = 0; i < pixel_count; ++i) {
      DecodeColor(source + size_t(i) * texel_size, capture.format,
                  image.rgba.data() + size_t(i) * 4);
    }
    WritePng(frame_directory_ / xe::to_path(stem + ".png"), capture.width,
             capture.height, image.rgba.data());
    html += fmt::format("<img src=\"{}.png\">\n", stem);
  }

  // Diff against the same attachment of the same pass in the previous captured
  // frame. This is the reason the tool captures more than one frame: an
  // artifact that is only wrong relative to the frame before it does not appear
  // in any single image.
  for (const PreviousImage& previous : previous_images_) {
    if (previous.pass_index != capture.pass_index ||
        previous.attachment != capture.attachment ||
        previous.width != capture.width || previous.height != capture.height) {
      continue;
    }
    std::vector<uint8_t> diff(size_t(pixel_count) * 4);
    uint32_t changed = 0;
    if (is_depth && !previous.depth.empty()) {
      // Diffed in guest depth units rather than on the 8-bit greyscale, which
      // would quantise away exactly the small movements this is looking for.
      double total = 0.0;
      float worst = 0.0f;
      for (uint32_t i = 0; i < pixel_count; ++i) {
        const float difference = std::fabs(image.depth[i] - previous.depth[i]);
        if (difference > 0.0f) {
          ++changed;
          total += difference;
          worst = std::max(worst, difference);
        }
        const uint8_t value = ToByte(difference * float(1 << 16));
        diff[size_t(i) * 4 + 0] = value;
        diff[size_t(i) * 4 + 1] = value;
        diff[size_t(i) * 4 + 2] = value;
        diff[size_t(i) * 4 + 3] = 255;
      }
      html += fmt::format(
          "<p class=\"diff\">vs previous frame: {} px ({:.2f}%) changed, mean "
          "{:.3e}, worst {:.3e}</p>\n",
          changed, 100.0 * double(changed) / double(std::max(1u, pixel_count)),
          changed ? total / double(changed) : 0.0, worst);
    } else {
      for (uint32_t i = 0; i < pixel_count; ++i) {
        bool pixel_changed = false;
        for (uint32_t component = 0; component < 3; ++component) {
          const int difference =
              std::abs(int(image.rgba[size_t(i) * 4 + component]) -
                       int(previous.rgba[size_t(i) * 4 + component]));
          // Amplified so a one-step difference is visible; the shape of the
          // changed region says more than the count does.
          diff[size_t(i) * 4 + component] =
              uint8_t(std::min(255, difference * 4));
          pixel_changed = pixel_changed || difference != 0;
        }
        diff[size_t(i) * 4 + 3] = 255;
        changed += pixel_changed ? 1 : 0;
      }
      html += fmt::format(
          "<p class=\"diff\">vs previous frame: {} px ({:.2f}%) changed</p>\n",
          changed, 100.0 * double(changed) / double(std::max(1u, pixel_count)));
    }
    WritePng(frame_directory_ / xe::to_path(stem + "_diff.png"), capture.width,
             capture.height, diff.data());
    html += fmt::format("<img src=\"{}_diff.png\" title=\"difference x4\">\n",
                        stem);
    break;
  }

  current_images_.push_back(std::move(image));
  html += "</figure>\n";
  return html;
}

void VulkanFrameInspector::WriteReport() {
  const std::filesystem::path report_path = output_root_ / "report.html";
  std::string html =
      "<!doctype html>\n<meta charset=\"utf-8\">\n"
      "<title>Xenra frame inspector</title>\n"
      "<style>\n"
      "body{background:#151515;color:#ddd;font:13px system-ui,sans-serif;"
      "margin:16px}\n"
      "h2{border-bottom:1px solid #444;padding-bottom:4px;margin-top:32px}\n"
      "h3{color:#8cf;margin-bottom:2px}\n"
      ".meta{color:#999;margin:2px 0}\n"
      ".skip{color:#e97}\n"
      ".diff{color:#fc6;margin:2px 0}\n"
      ".row{display:flex;flex-wrap:wrap;gap:16px}\n"
      "figure{margin:0 0 16px;max-width:640px}\n"
      "img{max-width:300px;image-rendering:pixelated;border:1px solid #333;"
      "background:#000}\n"
      "pre{color:#bbb;background:#0d0d0d;padding:6px;overflow-x:auto}\n"
      "</style>\n";
  html += fmt::format(
      "<h1>Xenra frame inspector</h1>\n<p class=\"meta\">{} frame(s) from guest "
      "frame {}. Depth images: as stored, contrast-stretched, and the residual "
      "against the guest's 20e4 format. Where a second frame exists, each "
      "attachment also carries its difference from the previous frame.</p>\n",
      frames_captured_, capture_start_frame_);
  html += report_body_;

  FILE* file = xe::filesystem::OpenFile(report_path, "wb");
  if (!file) {
    XELOGE("FrameInspector: failed to open {} for writing",
           xe::path_to_utf8(report_path));
    return;
  }
  fwrite(html.data(), 1, html.size(), file);
  fclose(file);
  XELOGI("FrameInspector: report written to {}", xe::path_to_utf8(report_path));
}

}  // namespace vulkan
}  // namespace gpu
}  // namespace xe
