/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/vfs/iso_metadata.h"

#include <cstring>
#include <fstream>
#include <vector>

#include "xenia/base/mapped_memory.h"
#include "xenia/kernel/util/xex2_info.h"
#include "xenia/vfs/gdfx_util.h"

namespace xe {
namespace vfs {

namespace {

// The same partition walk as ExtractIsoMetadata(const uint8_t*, size_t), but
// reading only the sectors it needs. A 7.8 GB ISO cannot be mapped on iOS: the
// mmap reserves the whole file and fails with ENOMEM against the process limit,
// which left the title ID unknown and every per-game config and quirk dormant.
std::optional<XexMetadata> ExtractIsoMetadataStreamed(
    const std::filesystem::path& path) {
  std::ifstream file(path, std::ios::binary);
  if (!file) {
    return std::nullopt;
  }
  file.seekg(0, std::ios::end);
  const std::streamoff end = file.tellg();
  if (end <= 0) {
    return std::nullopt;
  }
  const uint64_t size = static_cast<uint64_t>(end);

  const auto read_at = [&](uint64_t offset, void* buffer, size_t length) {
    if (offset > size || size - offset < length) {
      return false;
    }
    file.clear();
    file.seekg(static_cast<std::streamoff>(offset));
    file.read(reinterpret_cast<char*>(buffer),
              static_cast<std::streamsize>(length));
    return file && static_cast<size_t>(file.gcount()) == length;
  };

  for (const size_t partition_offset : kGdfxLikelyOffsets) {
    // The filesystem descriptor is sector 32 of the game partition.
    const uint64_t sector32 =
        uint64_t(partition_offset) + uint64_t(32) * kGdfxSectorSize;
    uint8_t fs[28];
    if (!read_at(sector32, fs, sizeof(fs))) {
      continue;
    }
    if (std::memcmp(fs, kGdfxMagic, kGdfxMagicSize) != 0) {
      continue;
    }
    const uint32_t root_sector = xe::load<uint32_t>(fs + 20);
    const uint32_t root_size = xe::load<uint32_t>(fs + 24);
    if (root_size < 13 || root_size > 32 * 1024 * 1024) {
      continue;
    }
    const uint64_t root_offset =
        uint64_t(partition_offset) + uint64_t(root_sector) * kGdfxSectorSize;
    std::vector<uint8_t> root(root_size);
    if (!read_at(root_offset, root.data(), root.size())) {
      continue;
    }
    auto location = detail::GdfxFindFileInDirectory(
        nullptr, static_cast<size_t>(size), partition_offset, root.data(),
        root.size(), 0, "default.xex", 11, 0);
    if (!location || location->offset > size ||
        size - location->offset < location->length) {
      continue;
    }

    xex2_header base_header;
    if (!read_at(location->offset, &base_header, sizeof(base_header))) {
      continue;
    }
    const uint32_t header_size = base_header.header_size;
    if (header_size < sizeof(base_header) || header_size > location->length ||
        header_size > 16 * 1024 * 1024) {
      continue;
    }
    std::vector<uint8_t> header_data(header_size);
    if (!read_at(location->offset, header_data.data(), header_data.size())) {
      continue;
    }
    return ExtractXexMetadata(header_data.data(), header_data.size());
  }
  return std::nullopt;
}

}  // namespace

std::optional<XexMetadata> ExtractIsoMetadata(const uint8_t* data,
                                              size_t size) {
  // Find the game partition.
  auto partition = GdfxFindPartition(data, size);
  if (!partition) {
    return std::nullopt;
  }

  // Find default.xex in the root directory.
  auto location = GdfxFindFile(data, size, *partition, "default.xex");
  if (!location) {
    return std::nullopt;
  }

  // Validate the file location.
  if (location->offset + location->length > size) {
    return std::nullopt;
  }

  // Extract XEX metadata from the file data.
  return ExtractXexMetadata(data + location->offset, location->length);
}

std::optional<XexMetadata> ExtractIsoMetadata(
    const std::filesystem::path& path) {
  // Memory-map small images for the fast path; fall back to bounded reads when
  // the mapping is refused (the norm for a multi-gigabyte ISO on iOS).
  auto mmap = xe::MappedMemory::Open(path, xe::MappedMemory::Mode::kRead);
  if (mmap) {
    return ExtractIsoMetadata(mmap->data(), mmap->size());
  }
  return ExtractIsoMetadataStreamed(path);
}

}  // namespace vfs
}  // namespace xe
