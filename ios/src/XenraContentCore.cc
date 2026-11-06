/**
 ******************************************************************************
 * Xenra : iOS shell - the core's content installer                            *
 ******************************************************************************
 *
 * The three calls XenraContentInstall.mm needs, as plain C, so the shell can be
 * built for the simulator with no core. Android's are in emulator_xendroid.cpp.
 * They need no running emulator. All block, and all run off the main thread.
 */

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include "xenia/vfs/content_install_standalone.h"

namespace {
xe::vfs::ContentProgress g_progress;
}

extern "C" {

// Returns X_STATUS, 0 on success.
int xenra_content_install(const char* source, const char* content_root) {
  return static_cast<int>(xe::vfs::InstallContentPackageStandalone(
      std::filesystem::u8path(source), std::filesystem::u8path(content_root),
      g_progress, 0));
}

float xenra_content_progress(void) {
  const uint64_t total = g_progress.total.load();
  return total ? static_cast<float>(static_cast<double>(g_progress.current.load()) /
                                    static_cast<double>(total))
               : -1.0f;
}

// Fills out with malloc'd copies of the inner paths, up to capacity, and gives
// the number found. The caller frees each.
int xenra_content_list_disc(const char* disc, char** out, int capacity) {
  const std::vector<xe::vfs::DiscContentItem> items =
      xe::vfs::ListDiscContent(std::filesystem::u8path(disc));
  int count = 0;
  for (const xe::vfs::DiscContentItem& item : items) {
    if (count == capacity) break;
    out[count++] = strdup(item.inner_path.c_str());
  }
  return count;
}

int xenra_content_install_disc(const char* disc, const char* inner_path,
                               const char* content_root, const char* scratch) {
  return static_cast<int>(xe::vfs::InstallDiscContentPackage(
      std::filesystem::u8path(disc), inner_path,
      std::filesystem::u8path(content_root), std::filesystem::u8path(scratch),
      g_progress));
}

}  // extern "C"
