/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/ui/vulkan/vulkan_diagnostics.h"

#include <cstdio>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <mutex>
#include <string>
#include <vector>

#include "third_party/fmt/include/fmt/format.h"
#include "xenia/base/cvar.h"
#include "xenia/base/logging.h"
#include "xenia/base/platform.h"

#if XE_PLATFORM_xendroid || XE_PLATFORM_ANDROID
#include <sys/system_properties.h>
#endif

DEFINE_string(
    gpu_diagnostic_report, "",
    "Path of a human-readable GPU capability report written at startup. Empty "
    "uses the platform default (the Download folder on Android, where a file "
    "manager can reach it); 'off' disables the report entirely.",
    "GPU");

// Defined by the logging layer on this platform (XE_PLATFORM_ANDROID is not
// set for the fork - see platform.h). Used only for its directory, as the
// always-writable last resort when the Download folder is not permitted.
DECLARE_path(log_file);

namespace xe {
namespace ui {
namespace vulkan {

namespace {

std::mutex& ReportMutex() {
  static std::mutex mutex;
  return mutex;
}

std::string& ReportText() {
  static std::string text;
  return text;
}

// Resolved once, on the first successful write, and reused after that.
std::string& ReportPath() {
  static std::string path;
  return path;
}

// Ordered best-first. The Download folder is the only location the person
// running the build can open in a file manager on Android 11+, but writing
// there needs All-files access to have been granted - which a remote tester
// may well not have done. Falling back beside the Xenia log means a report is
// still produced in that case, retrievable over adb or via SAF.
std::vector<std::string> CandidateReportPaths() {
  std::vector<std::string> paths;
  if (!cvars::gpu_diagnostic_report.empty()) {
    paths.push_back(cvars::gpu_diagnostic_report);
    return paths;
  }
#if XE_PLATFORM_xendroid || XE_PLATFORM_ANDROID
  paths.push_back("/sdcard/Download/xenra-gpu-report.txt");
  paths.push_back("/storage/emulated/0/Download/xenra-gpu-report.txt");
  paths.push_back("/sdcard/xenra-gpu-report.txt");
  if (!cvars::log_file.empty()) {
    paths.push_back(
        (cvars::log_file.parent_path() / "xenra-gpu-report.txt").string());
  }
#else
  paths.push_back("xenra-gpu-report.txt");
#endif
  return paths;
}

// Rewritten in full on every append, so a hang or a hard crash part-way through
// initialization still leaves everything gathered up to that point on disk.
void FlushReportLocked() {
  if (cvars::gpu_diagnostic_report == "off") {
    return;
  }
  const std::string& text = ReportText();
  if (!ReportPath().empty()) {
    if (FILE* const file = std::fopen(ReportPath().c_str(), "wb")) {
      std::fwrite(text.data(), 1, text.size(), file);
      std::fclose(file);
    }
    return;
  }
  for (const std::string& candidate : CandidateReportPaths()) {
    FILE* const file = std::fopen(candidate.c_str(), "wb");
    if (!file) {
      continue;
    }
    std::fwrite(text.data(), 1, text.size(), file);
    std::fclose(file);
    ReportPath() = candidate;
    return;
  }
}

void Append(const std::string& line) {
  std::lock_guard<std::mutex> lock(ReportMutex());
  ReportText() += line;
  ReportText() += '\n';
  FlushReportLocked();
}

std::string Flag(const char* const name, bool value) {
  return fmt::format("    [{}] {}", value ? 'x' : ' ', name);
}

#if XE_PLATFORM_xendroid || XE_PLATFORM_ANDROID
std::string SystemProperty(const char* const name) {
  char value[PROP_VALUE_MAX] = {};
  const int length = __system_property_get(name, value);
  return length > 0 ? std::string(value, size_t(length)) : std::string();
}
#endif

std::string DeviceTypeName(VkPhysicalDeviceType type) {
  switch (type) {
    case VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU:
      return "integrated GPU";
    case VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU:
      return "discrete GPU";
    case VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU:
      return "virtual GPU";
    case VK_PHYSICAL_DEVICE_TYPE_CPU:
      return "CPU";
    default:
      return "other/unknown";
  }
}

// Names the part vendor rather than trusting the marketing string, because the
// whole point of the report is to identify hardware nobody here has held.
std::string VendorName(uint32_t vendor_id) {
  switch (vendor_id) {
    case 0x13B5:
      return "ARM (Mali)";
    case 0x5143:
      return "Qualcomm (Adreno)";
    case 0x1010:
      return "Imagination (PowerVR)";
    case 0x10DE:
      return "NVIDIA";
    case 0x1002:
      return "AMD";
    case 0x8086:
      return "Intel";
    case 0x14E4:
      return "Broadcom";
    case 0x1AE0:
      return "Google (SwiftShader)";
    default:
      return "unknown";
  }
}

std::string ApiVersionString(uint32_t version) {
  return fmt::format("{}.{}.{}", VK_VERSION_MAJOR(version),
                     VK_VERSION_MINOR(version), VK_VERSION_PATCH(version));
}

void AppendHostSection() {
  Append("================================================================");
  Append("XENRA GPU DIAGNOSTIC REPORT");
  Append("================================================================");
  const std::time_t now = std::time(nullptr);
  char time_text[64] = {};
  std::strftime(time_text, sizeof(time_text), "%Y-%m-%d %H:%M:%S",
                std::localtime(&now));
  Append(fmt::format("generated       : {}", time_text));
#if XE_PLATFORM_xendroid || XE_PLATFORM_ANDROID
  Append("");
  Append("-- DEVICE ------------------------------------------------------");
  Append(fmt::format("manufacturer    : {}",
                     SystemProperty("ro.product.manufacturer")));
  Append(
      fmt::format("model           : {}", SystemProperty("ro.product.model")));
  Append(
      fmt::format("device          : {}", SystemProperty("ro.product.device")));
  Append(fmt::format("android release : {} (API {})",
                     SystemProperty("ro.build.version.release"),
                     SystemProperty("ro.build.version.sdk")));
  // The SoC properties are what separate a MediaTek part from a Qualcomm one
  // before any Vulkan call has been made.
  Append(fmt::format("soc manufacturer: {}",
                     SystemProperty("ro.soc.manufacturer")));
  Append(fmt::format("soc model       : {}", SystemProperty("ro.soc.model")));
  Append(fmt::format("board platform  : {}",
                     SystemProperty("ro.board.platform")));
  Append(fmt::format("hardware        : {}", SystemProperty("ro.hardware")));
  Append(fmt::format("abi             : {}",
                     SystemProperty("ro.product.cpu.abi")));
#endif
}

}  // namespace

void GpuDiagnosticNote(const std::string& line) { Append(line); }

void GpuDiagnosticStage(const char* const stage, bool succeeded) {
  Append(fmt::format("  {:<8} {}", succeeded ? "ok" : "*FAIL*", stage));
  if (!succeeded) {
    Append("");
    Append(fmt::format(">>> INITIALIZATION FAILED AT: {} <<<", stage));
    Append("Search the Xenia log for the matching 'Failed to ...' line.");
  }
}

void GpuDiagnosticReportDevices(
    const VulkanInstance* const vulkan_instance,
    const std::vector<VkPhysicalDevice>& physical_devices,
    const VulkanDevice* const vulkan_device) {
  AppendHostSection();

  Append("");
  Append("-- VULKAN INSTANCE ---------------------------------------------");
  Append(fmt::format("instance api    : {}",
                     ApiVersionString(vulkan_instance->api_version())));
  Append(fmt::format("physical devices: {}", physical_devices.size()));

  const VulkanInstance::Functions& ifn = vulkan_instance->functions();

  for (size_t i = 0; i < physical_devices.size(); ++i) {
    const VkPhysicalDevice physical_device = physical_devices[i];

    VkPhysicalDeviceProperties properties = {};
    ifn.vkGetPhysicalDeviceProperties(physical_device, &properties);
    VkPhysicalDeviceFeatures features = {};
    ifn.vkGetPhysicalDeviceFeatures(physical_device, &features);

    Append("");
    Append(fmt::format(
        "-- PHYSICAL DEVICE {} -------------------------------------------",
        i));
    Append(fmt::format("name            : {}", properties.deviceName));
    Append(fmt::format("type            : {}",
                       DeviceTypeName(properties.deviceType)));
    Append(fmt::format("vendor          : 0x{:04X} ({})", properties.vendorID,
                       VendorName(properties.vendorID)));
    Append(fmt::format("device id       : 0x{:04X}", properties.deviceID));
    Append(fmt::format("driver version  : 0x{:08X} ({})",
                       properties.driverVersion,
                       ApiVersionString(properties.driverVersion)));
    Append(fmt::format("device api      : {}",
                       ApiVersionString(properties.apiVersion)));

    // The one feature whose absence makes CreateIfSupported reject the device
    // outright, so it is called out before the full list.
    Append("");
    if (!features.independentBlend) {
      Append("*** independentBlend IS NOT SUPPORTED - this device is");
      Append("*** REJECTED outright by VulkanDevice::CreateIfSupported.");
    }

    Append("core features used by the emulator:");
    Append(Flag("independentBlend            (REQUIRED)",
                features.independentBlend != VK_FALSE));
    Append(Flag("geometryShader              (else VS expansion)",
                features.geometryShader != VK_FALSE));
    Append(Flag("tessellationShader          (optional)",
                features.tessellationShader != VK_FALSE));
    Append(Flag("fragmentStoresAndAtomics    (else no FSI path)",
                features.fragmentStoresAndAtomics != VK_FALSE));
    Append(Flag("vertexPipelineStoresAndAtomics (else compute memexport)",
                features.vertexPipelineStoresAndAtomics != VK_FALSE));
    Append(Flag("sparseBinding               (else non-sparse shared memory)",
                features.sparseBinding != VK_FALSE));
    Append(Flag("sparseResidencyBuffer",
                features.sparseResidencyBuffer != VK_FALSE));
    Append(
        Flag("fullDrawIndexUint32", features.fullDrawIndexUint32 != VK_FALSE));
    Append(Flag("shaderClipDistance", features.shaderClipDistance != VK_FALSE));
    Append(Flag("shaderCullDistance", features.shaderCullDistance != VK_FALSE));
    Append(Flag("shaderInt16", features.shaderInt16 != VK_FALSE));
    Append(Flag("samplerAnisotropy", features.samplerAnisotropy != VK_FALSE));
    Append(Flag("depthClamp", features.depthClamp != VK_FALSE));
    Append(Flag("fillModeNonSolid", features.fillModeNonSolid != VK_FALSE));
    Append(Flag("occlusionQueryPrecise",
                features.occlusionQueryPrecise != VK_FALSE));
    Append(Flag("sampleRateShading", features.sampleRateShading != VK_FALSE));
    Append(Flag("robustBufferAccess", features.robustBufferAccess != VK_FALSE));
    Append(Flag("textureCompressionBC",
                features.textureCompressionBC != VK_FALSE));

    Append("");
    Append("limits that gate emulator paths:");
    Append(fmt::format("    maxStorageBufferRange        : {}",
                       properties.limits.maxStorageBufferRange));
    Append(fmt::format("    maxImageDimension2D          : {}",
                       properties.limits.maxImageDimension2D));
    Append(fmt::format("    maxUniformBufferRange        : {}",
                       properties.limits.maxUniformBufferRange));
    Append(fmt::format("    maxDescriptorSetUniformBuffersDynamic: {}",
                       properties.limits.maxDescriptorSetUniformBuffersDynamic));
    Append(fmt::format("    maxPerStageDescriptorSamplers: {}",
                       properties.limits.maxPerStageDescriptorSamplers));
    Append(fmt::format("    maxFragmentCombinedOutputResources: {}",
                       properties.limits.maxFragmentCombinedOutputResources));
    Append(fmt::format("    maxFramebufferWidth x Height : {} x {}",
                       properties.limits.maxFramebufferWidth,
                       properties.limits.maxFramebufferHeight));

    // Extension list, filtered to the ones that change which path is taken.
    uint32_t extension_count = 0;
    if (ifn.vkEnumerateDeviceExtensionProperties(
            physical_device, nullptr, &extension_count, nullptr) == VK_SUCCESS &&
        extension_count) {
      std::vector<VkExtensionProperties> extensions(extension_count);
      if (ifn.vkEnumerateDeviceExtensionProperties(
              physical_device, nullptr, &extension_count, extensions.data()) ==
          VK_SUCCESS) {
        static const char* const kInterestingExtensions[] = {
            "VK_KHR_swapchain",
            "VK_EXT_fragment_shader_interlock",
            "VK_EXT_external_memory_host",
            "VK_KHR_dynamic_rendering",
            "VK_KHR_dynamic_rendering_local_read",
            "VK_EXT_extended_dynamic_state3",
            "VK_EXT_shader_stencil_export",
            "VK_EXT_subgroup_size_control",
            "VK_EXT_custom_border_color",
            "VK_EXT_non_seamless_cube_map",
            "VK_KHR_fragment_shader_barycentric",
            "VK_EXT_device_fault",
            "VK_EXT_memory_budget",
            "VK_KHR_shader_float16_int8",
        };
        Append("");
        Append(fmt::format("extensions ({} total; the ones that matter):",
                           extension_count));
        for (const char* const wanted : kInterestingExtensions) {
          bool present = false;
          for (const VkExtensionProperties& extension : extensions) {
            if (!std::strcmp(extension.extensionName, wanted)) {
              present = true;
              break;
            }
          }
          Append(Flag(wanted, present));
        }
      }
    }

    // Memory heaps - a Mali part is unified memory, so a large device-local
    // allocation for shared memory competes with the rest of the system.
    VkPhysicalDeviceMemoryProperties memory_properties = {};
    ifn.vkGetPhysicalDeviceMemoryProperties(physical_device,
                                            &memory_properties);
    Append("");
    Append("memory heaps:");
    for (uint32_t heap_index = 0;
         heap_index < memory_properties.memoryHeapCount; ++heap_index) {
      const VkMemoryHeap& heap = memory_properties.memoryHeaps[heap_index];
      Append(fmt::format("    heap {}: {} MB{}", heap_index,
                         heap.size / (1024 * 1024),
                         (heap.flags & VK_MEMORY_HEAP_DEVICE_LOCAL_BIT)
                             ? " (device local)"
                             : ""));
    }
  }

  Append("");
  Append("-- SELECTION ---------------------------------------------------");
  if (vulkan_device) {
    const VulkanDevice::Properties& device_properties =
        vulkan_device->properties();
    Append(fmt::format("chosen device   : {}", device_properties.deviceName));
    Append("");
    Append("features actually ENABLED on the logical device (these, not the");
    Append("raw support above, decide which emulator paths run):");
    Append(Flag("geometryShader", device_properties.geometryShader));
    Append(Flag("tessellationShader", device_properties.tessellationShader));
    Append(Flag("fragmentStoresAndAtomics",
                device_properties.fragmentStoresAndAtomics));
    Append(Flag("vertexPipelineStoresAndAtomics",
                device_properties.vertexPipelineStoresAndAtomics));
    Append(Flag("sparseBinding", device_properties.sparseBinding));
    Append(
        Flag("sparseResidencyBuffer", device_properties.sparseResidencyBuffer));
    Append(Flag("fragmentShaderSampleInterlock",
                device_properties.fragmentShaderSampleInterlock));
    Append(Flag("fragmentShaderPixelInterlock",
                device_properties.fragmentShaderPixelInterlock));
    Append(Flag("triangleFans", device_properties.triangleFans));
    Append(Flag("fullDrawIndexUint32", device_properties.fullDrawIndexUint32));
    Append(Flag("shaderFloat16", device_properties.shaderFloat16));
    Append(Flag("dynamicRendering", device_properties.dynamicRendering));
    Append(Flag("extendedDynamicState", device_properties.extendedDynamicState));
    Append(Flag("shaderDemoteToHelperInvocation",
                device_properties.shaderDemoteToHelperInvocation));
    Append(fmt::format("    subgroupSize: {}", device_properties.subgroupSize));
    Append(fmt::format("    external_memory_host: {}",
                       vulkan_device->extensions().ext_EXT_external_memory_host
                           ? "yes"
                           : "no"));
  } else {
    Append("*** NO COMPATIBLE VULKAN DEVICE COULD BE CREATED. ***");
    Append("Nothing below this point ran. The per-device feature lists above");
    Append("say why: check independentBlend first, then the swapchain and");
    Append("graphics+compute queue requirements.");
  }

  Append("");
  Append("-- INITIALIZATION STAGES ---------------------------------------");

  // Mirror the whole report into the Xenia log as well, at error level, so it
  // survives regardless of log_level and is present in a log retrieved by
  // other means.
  std::lock_guard<std::mutex> lock(ReportMutex());
  XELOGE("GPU diagnostic report written to '{}':\n{}",
         ReportPath().empty() ? "<no writable location>" : ReportPath(),
         ReportText());
}

}  // namespace vulkan
}  // namespace ui
}  // namespace xe
