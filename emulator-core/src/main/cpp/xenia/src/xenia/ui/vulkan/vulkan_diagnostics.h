/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_UI_VULKAN_VULKAN_DIAGNOSTICS_H_
#define XENIA_UI_VULKAN_VULKAN_DIAGNOSTICS_H_

#include <string>
#include <vector>

#include "xenia/ui/vulkan/vulkan_device.h"
#include "xenia/ui/vulkan/vulkan_instance.h"

namespace xe {
namespace ui {
namespace vulkan {

// A standalone, human-readable GPU capability report, written to a file the
// person running the build can actually reach (the Xenia log lives under
// Android/data, which a file manager cannot open on Android 11+).
//
// This exists to make a single run on an unfamiliar GPU - a Mali or PowerVR
// part, where none of this code has ever been exercised - enough to identify
// why initialization failed, without that person having to run adb.

// Records every physical device the loader offered, its raw (pre-selection)
// feature set, and which one was chosen. `vulkan_device` is null when no
// device could be created at all, which is itself the most important case.
void GpuDiagnosticReportDevices(
    const VulkanInstance* vulkan_instance,
    const std::vector<VkPhysicalDevice>& physical_devices,
    const VulkanDevice* vulkan_device);

// Marks an initialization step as reached and whether it succeeded. The last
// stage in the report is the one that failed.
void GpuDiagnosticStage(const char* stage, bool succeeded);

// Free-form line appended to the report.
void GpuDiagnosticNote(const std::string& line);

}  // namespace vulkan
}  // namespace ui
}  // namespace xe

#endif  // XENIA_UI_VULKAN_VULKAN_DIAGNOSTICS_H_
