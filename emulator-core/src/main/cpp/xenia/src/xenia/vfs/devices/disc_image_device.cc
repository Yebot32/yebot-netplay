/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2020 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/vfs/devices/disc_image_device.h"

#include <algorithm>
#include <cstring>

#include "xenia/base/filesystem.h"
#include "xenia/base/literals.h"
#include "xenia/base/logging.h"
#include "xenia/base/math.h"
#include "xenia/vfs/devices/disc_image_entry.h"
#include "xenia/vfs/gdfx_util.h"

namespace xe {
namespace vfs {

using namespace xe::literals;

DiscImageDevice::DiscImageDevice(const std::string_view mount_path,
                                 const std::filesystem::path& host_path)
    : Device(mount_path), name_("GDFX"), host_path_(host_path) {}

DiscImageDevice::~DiscImageDevice() {
  if (file_) {
    fclose(file_);
  }
}

bool DiscImageDevice::Initialize() {
  ParseState state = {0};
  mmap_ = MappedMemory::Open(host_path_, MappedMemory::Mode::kRead);
  if (mmap_) {
    XELOGFS("DiscImageDevice::Initialize");
    image_size_ = mmap_->size();
    state.ptr = mmap_->data();
    state.size = mmap_->size();
  } else {
    // Too big to map in one piece on some hosts. Read it as it is needed.
    std::error_code error;
    image_size_ = size_t(std::filesystem::file_size(host_path_, error));
    file_ = error ? nullptr : xe::filesystem::OpenFile(host_path_, "rb");
    if (!file_ || !image_size_) {
      XELOGE("Disc image could not be mapped or opened");
      return false;
    }
    XELOGI("Disc image is read on demand ({} bytes)", image_size_);
    state.ptr = nullptr;
    state.size = image_size_;
  }

  auto result = mmap_ ? Verify(&state) : VerifyByReading(&state);
  if (result != Error::kSuccess) {
    XELOGE("Failed to verify disc image header: {}",
           static_cast<int32_t>(result));
    return false;
  }

  std::vector<uint8_t> root_storage;
  const uint8_t* root_table = DirectoryTable(&state, state.root_offset,
                                             state.root_size, root_storage);
  if (!root_table) {
    XELOGE("Failed to read the GDFX root directory");
    return false;
  }
  result = ReadAllEntries(&state, root_table);
  if (result != Error::kSuccess) {
    XELOGE("Failed to read all GDFX entries: {}", static_cast<int32_t>(result));
    return false;
  }

  return true;
}

bool DiscImageDevice::ReadAt(size_t offset, void* out, size_t length) {
  if (offset > image_size_ || length > image_size_ - offset) {
    return false;
  }
  if (mmap_) {
    std::memcpy(out, mmap_->data() + offset, length);
    return true;
  }
  std::lock_guard<std::mutex> lock(file_lock_);
  return file_ && xe::filesystem::Seek(file_, int64_t(offset), SEEK_SET) &&
         fread(out, 1, length, file_) == length;
}

DiscImageDevice::Error DiscImageDevice::VerifyByReading(ParseState* state) {
  // GdfxFindPartition's checks, one small read per candidate offset.
  for (size_t offset : kGdfxLikelyOffsets) {
    const size_t sector32 = offset + (32 * kGdfxSectorSize);
    uint8_t header[28];
    if (!ReadAt(sector32, header, sizeof(header)) ||
        std::memcmp(header, kGdfxMagic, kGdfxMagicSize) != 0) {
      continue;
    }
    const uint32_t root_sector = xe::load<uint32_t>(header + 20);
    const uint32_t root_size = xe::load<uint32_t>(header + 24);
    if (root_size < 13 || root_size > 32 * 1024 * 1024) {
      continue;
    }
    state->game_offset = offset;
    state->root_sector = root_sector;
    state->root_size = root_size;
    state->root_offset = offset + (size_t(root_sector) * kGdfxSectorSize);
    return Error::kSuccess;
  }
  return Error::kErrorFileMismatch;
}

const uint8_t* DiscImageDevice::DirectoryTable(ParseState* state, size_t offset,
                                               size_t length,
                                               std::vector<uint8_t>& storage) {
  if (state->ptr) {
    return offset < state->size ? state->ptr + offset : nullptr;
  }
  // Whole sectors, as on the disc, plus slack for the last entry's header.
  const size_t padded = xe::round_up(length, kGdfxSectorSize);
  storage.assign(padded + kGdfxSectorSize, 0);
  const size_t available =
      offset < image_size_ ? std::min(padded, image_size_ - offset) : 0;
  if (!available || !ReadAt(offset, storage.data(), available)) {
    return nullptr;
  }
  return storage.data();
}

void DiscImageDevice::Dump(StringBuffer* string_buffer) {
  auto global_lock = global_critical_region_.Acquire();
  root_entry_->Dump(string_buffer, 0);
}

Entry* DiscImageDevice::ResolvePath(const std::string_view path) {
  // The filesystem will have stripped our prefix off already, so the path will
  // be in the form:
  // some\PATH.foo
  XELOGFS("DiscImageDevice::ResolvePath({})", path);
  return root_entry_->ResolvePath(path);
}

DiscImageDevice::Error DiscImageDevice::Verify(ParseState* state) {
  // Use shared GDFX utility to find the game partition.
  auto partition = GdfxFindPartition(state->ptr, state->size);
  if (!partition) {
    return Error::kErrorFileMismatch;
  }

  state->game_offset = partition->game_offset;
  state->root_sector = partition->root_sector;
  state->root_size = partition->root_size;
  state->root_offset =
      state->game_offset + (state->root_sector * kGdfxSectorSize);

  return Error::kSuccess;
}

bool DiscImageDevice::VerifyMagic(ParseState* state, size_t offset) {
  return GdfxVerifyMagic(state->ptr, state->size, offset);
}

DiscImageDevice::Error DiscImageDevice::ReadAllEntries(
    ParseState* state, const uint8_t* root_buffer) {
  auto root_entry = new DiscImageEntry(this, nullptr, "", mmap_.get());
  root_entry->attributes_ = kFileAttributeDirectory;
  root_entry_ = std::unique_ptr<Entry>(root_entry);

  if (!ReadEntry(state, root_buffer, 0, root_entry)) {
    return Error::kErrorOutOfMemory;
  }

  return Error::kSuccess;
}

bool DiscImageDevice::ReadEntry(ParseState* state, const uint8_t* buffer,
                                uint32_t entry_ordinal,
                                DiscImageEntry* parent) {
  const uint8_t* p = buffer + (entry_ordinal * 4);

  uint16_t node_l = xe::load<uint16_t>(p + 0);
  uint16_t node_r = xe::load<uint16_t>(p + 2);
  size_t sector = xe::load<uint32_t>(p + 4);
  size_t length = xe::load<uint32_t>(p + 8);
  uint8_t attributes = xe::load<uint8_t>(p + 12);
  uint8_t name_length = xe::load<uint8_t>(p + 13);
  auto name_buffer = reinterpret_cast<const char*>(p + 14);

  if (node_l == kGdfxPaddingOffset) {
    const uint32_t padded_ordinal = GdfxPaddedEntryOrdinal(entry_ordinal);
    return !padded_ordinal || ReadEntry(state, buffer, padded_ordinal, parent);
  }

  if (node_l && !ReadEntry(state, buffer, node_l, parent)) {
    return false;
  }

  // Filename is stored as Windows-1252, convert it to UTF-8.
  auto ansi_name = std::string(name_buffer, name_length);
  auto name = xe::win1252_to_utf8(ansi_name);
  // Fallback to normal name if for whatever reason conversion from 1252 code
  // page failed.
  if (name.empty()) {
    name = ansi_name;
  }

  auto entry = DiscImageEntry::Create(this, parent, name, mmap_.get());
  entry->attributes_ = attributes | kFileAttributeReadOnly;
  entry->size_ = length;
  entry->allocation_size_ = xe::round_up(length, bytes_per_sector());

  // Set to January 1, 1970 (UTC) in 100-nanosecond intervals
  entry->create_timestamp_ = 10000 * 11644473600000LL;
  entry->access_timestamp_ = 10000 * 11644473600000LL;
  entry->write_timestamp_ = 10000 * 11644473600000LL;

  if (attributes & kFileAttributeDirectory) {
    // Folder.
    entry->data_offset_ = 0;
    entry->data_size_ = 0;
    if (length) {
      // Not a leaf - read in children.
      if (state->size < state->game_offset + (sector * kGdfxSectorSize)) {
        // Out of bounds read.
        return false;
      }
      // Read child list.
      std::vector<uint8_t> folder_storage;
      const uint8_t* folder_ptr = DirectoryTable(
          state, state->game_offset + (sector * kGdfxSectorSize), length,
          folder_storage);
      if (!folder_ptr || !ReadEntry(state, folder_ptr, 0, entry.get())) {
        return false;
      }
    }
  } else {
    // File.
    entry->data_offset_ = state->game_offset + (sector * kGdfxSectorSize);
    entry->data_size_ = length;
  }

  // Add to parent.
  parent->children_.emplace_back(std::move(entry));

  // Read next file in the list.
  if (node_r && !ReadEntry(state, buffer, node_r, parent)) {
    return false;
  }

  return true;
}

}  // namespace vfs
}  // namespace xe
