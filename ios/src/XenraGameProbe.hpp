/**
 ******************************************************************************
 * Xenra : iOS shell - header reads for game containers                        *
 ******************************************************************************
 *
 * Plain C++ on a file descriptor, with no Apple headers, so these reads can be
 * built and run against real game files on any POSIX machine. A scan touches a
 * few kilobytes of a file, never the whole thing.
 *
 * The layouts come from the core and the Android library:
 *   XContent  xenia/vfs/devices/stfs_xbox.h
 *   XDVDFS    xenia/vfs/gdfx_util.h, GameLibraryActivity.readDiscImageFormat
 *   XEX2      xenia/kernel/util/xex2_info.h
 * XBE is not in the tree; its header and certificate offsets are the published
 * format.
 *
 * Every read is bounds checked against the file, and every function returns
 * false on anything it does not recognise. Nothing here throws.
 */

#ifndef XENRA_GAME_PROBE_HPP_
#define XENRA_GAME_PROBE_HPP_

#include <unistd.h>

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace xenra {
namespace probe {

inline bool ReadAt(int fd, uint64_t offset, void* out, size_t length) {
  uint8_t* dst = static_cast<uint8_t*>(out);
  while (length) {
    const ssize_t got = pread(fd, dst, length, static_cast<off_t>(offset));
    if (got <= 0) return false;
    dst += got;
    offset += static_cast<uint64_t>(got);
    length -= static_cast<size_t>(got);
  }
  return true;
}

inline uint16_t Be16(const uint8_t* p) {
  return static_cast<uint16_t>((p[0] << 8) | p[1]);
}
inline uint32_t Be32(const uint8_t* p) {
  return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
         (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}
inline uint64_t Be64(const uint8_t* p) {
  return (uint64_t(Be32(p)) << 32) | Be32(p + 4);
}
inline uint16_t Le16(const uint8_t* p) {
  return static_cast<uint16_t>(p[0] | (p[1] << 8));
}
inline uint32_t Le32(const uint8_t* p) {
  return uint32_t(p[0]) | (uint32_t(p[1]) << 8) | (uint32_t(p[2]) << 16) |
         (uint32_t(p[3]) << 24);
}

// UTF-16 to UTF-8, stopping at the first NUL or at count units. An unpaired
// surrogate becomes U+FFFD.
inline std::string Utf16ToUtf8(const uint8_t* p, size_t count, bool big_endian) {
  std::string out;
  const auto unit = [&](size_t i) -> uint32_t {
    return big_endian ? Be16(p + i * 2) : Le16(p + i * 2);
  };
  for (size_t i = 0; i < count; ++i) {
    uint32_t c = unit(i);
    if (c == 0) break;
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < count) {
      const uint32_t low = unit(i + 1);
      if (low >= 0xDC00 && low <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
        ++i;
      } else {
        c = 0xFFFD;
      }
    } else if (c >= 0xD800 && c <= 0xDFFF) {
      c = 0xFFFD;
    }
    if (c < 0x80) {
      out += static_cast<char>(c);
    } else if (c < 0x800) {
      out += static_cast<char>(0xC0 | (c >> 6));
      out += static_cast<char>(0x80 | (c & 0x3F));
    } else if (c < 0x10000) {
      out += static_cast<char>(0xE0 | (c >> 12));
      out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (c & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (c >> 18));
      out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (c & 0x3F));
    }
  }
  return out;
}

// Spaces at both ends go; a name made only of them, or holding a control
// character, is not a name.
inline std::string CleanTitle(std::string title) {
  while (!title.empty() && title.back() == ' ') title.pop_back();
  size_t start = 0;
  while (start < title.size() && title[start] == ' ') ++start;
  title.erase(0, start);
  for (const char c : title) {
    if (static_cast<unsigned char>(c) < 0x20) return std::string();
  }
  return title;
}

// --- File names ---------------------------------------------------------------

// Removes the trailing "(...)" and "[...]" groups, as
// Regex("(\\s*(\\([^\\)]*\\)|\\[[^\\]]*\\]))+$"). A group cannot contain its own
// closer, so it opens at the leftmost opener after the previous closer.
inline std::string StripTrailingGroups(std::string s) {
  const auto is_space = [](char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' ||
           c == '\r';
  };
  while (!s.empty()) {
    const char closer = s.back();
    if (closer != ')' && closer != ']') break;
    const char opener = closer == ')' ? '(' : '[';
    const size_t close = s.size() - 1;
    const size_t previous = close ? s.rfind(closer, close - 1) : std::string::npos;
    const size_t open =
        s.find(opener, previous == std::string::npos ? 0 : previous + 1);
    if (open == std::string::npos || open >= close) break;
    size_t start = open;
    while (start > 0 && is_space(s[start - 1])) --start;
    s.erase(start);
  }
  return s;
}

// GameLibraryActivity.toGameTitle, for the original Xbox. tagged says a group
// came off, which marks a file named by a disc set rather than by hand.
inline std::string OgTitleFromFileName(const std::string& file_name,
                                       bool* tagged) {
  constexpr char kXisoIso[] = ".xiso.iso";
  constexpr size_t kXisoIsoLength = sizeof(kXisoIso) - 1;
  std::string lower = file_name;
  for (char& c : lower) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
  }
  std::string raw = file_name;
  if (lower.size() >= kXisoIsoLength &&
      !lower.compare(lower.size() - kXisoIsoLength, kXisoIsoLength, kXisoIso)) {
    raw.resize(raw.size() - kXisoIsoLength);
  } else {
    const size_t dot = raw.rfind('.');
    if (dot != std::string::npos) raw.resize(dot);
  }
  const auto tidy = [](const std::string& s) {
    std::string out;
    for (const char c : s) {
      const bool space = c == ' ' || c == '\t' || c == '\n' || c == '\v' ||
                         c == '\f' || c == '\r';
      if (!space) {
        out += c;
      } else if (!out.empty() && out.back() != ' ') {
        out += ' ';
      }
    }
    while (!out.empty() && out.back() == ' ') out.pop_back();
    return out;
  };
  const std::string whole = tidy(raw);
  const std::string cleaned = tidy(StripTrailingGroups(raw));
  if (tagged) *tagged = cleaned != whole;
  return cleaned.empty() ? whole : cleaned;
}

// --- XContent: GOD, STFS ------------------------------------------------------

// sizeof(XContentContainerHeader). The core refuses anything shorter.
constexpr uint64_t kContainerHeaderSize = 0x971A;

constexpr size_t kOffContentType = 0x344;
constexpr size_t kOffContentSize = 0x34C;
constexpr size_t kOffExecutionInfo = 0x354;
constexpr size_t kOffDataFileSize = 0x3A1;
constexpr size_t kOffVolumeType = 0x3A9;
constexpr size_t kOffDisplayName = 0x411;
constexpr size_t kOffTitleName = 0x1691;
constexpr size_t kOffThumbnailSize = 0x1712;
constexpr size_t kOffTitleThumbnailSize = 0x1716;
constexpr size_t kOffThumbnail = 0x171A;
constexpr size_t kOffDisplayNameEx = 0x541A;
constexpr size_t kOffTitleThumbnail = 0x571A;

constexpr uint32_t kThumbMax = 0x4000;
constexpr size_t kDisplayNameSlots = 9;
constexpr size_t kDisplayNameExSlots = 3;
constexpr size_t kNameSlotBytes = 256;

// ContentPaths.isLaunchableGameType. Everything else in a container is add-on
// content: DLC, a title update, a profile, a save.
inline bool IsLaunchableContentType(uint32_t type) {
  return type == 0x00004000 ||  // installed game (GOD)
         type == 0x00007000 ||  // Xbox 360 title
         type == 0x000D0000 ||  // arcade title
         type == 0x00080000 ||  // game demo
         type == 0x02000000;    // community game
}

inline bool IsContainerMagic(const uint8_t* p) {
  return !std::memcmp(p, "CON ", 4) || !std::memcmp(p, "LIVE", 4) ||
         !std::memcmp(p, "PIRS", 4);
}

struct ContainerInfo {
  uint32_t content_type = 0;
  uint64_t content_size = 0;
  uint64_t data_file_size = 0;  // the "<name>.data" payload of a GOD
  uint32_t media_id = 0;
  uint32_t title_id = 0;
  uint8_t disc_number = 0;
  uint8_t disc_count = 0;
  bool svod = false;  // GOD; otherwise STFS
  std::string title_name;
  std::string display_name;
  uint64_t icon_offset = 0;
  uint32_t icon_size = 0;
};

inline bool ReadContainer(int fd, uint64_t file_size, ContainerInfo* out) {
  if (file_size < kContainerHeaderSize) return false;
  // Everything but the two thumbnails and the extra name slots.
  std::vector<uint8_t> h(kOffThumbnail);
  if (!ReadAt(fd, 0, h.data(), h.size())) return false;
  if (!IsContainerMagic(h.data())) return false;

  const uint8_t* b = h.data();
  out->content_type = Be32(b + kOffContentType);
  out->content_size = Be64(b + kOffContentSize);
  out->media_id = Be32(b + kOffExecutionInfo + 0x0);
  out->title_id = Be32(b + kOffExecutionInfo + 0xC);
  out->disc_number = b[kOffExecutionInfo + 0x12];
  out->disc_count = b[kOffExecutionInfo + 0x13];
  out->data_file_size = Be64(b + kOffDataFileSize);
  out->svod = Be32(b + kOffVolumeType) == 1;

  out->title_name = CleanTitle(Utf16ToUtf8(b + kOffTitleName, 64, true));

  // English is slot 0. Publishers misuse the slots, so the core falls through
  // to the first populated one, and so does this.
  out->display_name.clear();
  for (size_t slot = 0; slot < kDisplayNameSlots && out->display_name.empty();
       ++slot) {
    out->display_name = CleanTitle(
        Utf16ToUtf8(b + kOffDisplayName + slot * kNameSlotBytes, 128, true));
  }
  const uint32_t metadata_version = Be32(b + kOffContentType + 4);
  if (out->display_name.empty() && metadata_version >= 2) {
    uint8_t extra[kDisplayNameExSlots * kNameSlotBytes];
    if (ReadAt(fd, kOffDisplayNameEx, extra, sizeof(extra))) {
      for (size_t slot = 0;
           slot < kDisplayNameExSlots && out->display_name.empty(); ++slot) {
        out->display_name = CleanTitle(
            Utf16ToUtf8(extra + slot * kNameSlotBytes, 128, true));
      }
    }
  }

  // The core takes the title thumbnail. The package thumbnail is the same
  // picture on most titles, and better than nothing on the rest.
  const uint32_t title_thumb = Be32(b + kOffTitleThumbnailSize);
  const uint32_t thumb = Be32(b + kOffThumbnailSize);
  out->icon_offset = 0;
  out->icon_size = 0;
  if (title_thumb > 0 && title_thumb <= kThumbMax) {
    out->icon_offset = kOffTitleThumbnail;
    out->icon_size = title_thumb;
  } else if (thumb > 0 && thumb <= kThumbMax) {
    out->icon_offset = kOffThumbnail;
    out->icon_size = thumb;
  }
  return true;
}

// --- XEX ----------------------------------------------------------------------

struct XexInfo {
  uint32_t media_id = 0;
  uint32_t title_id = 0;
  uint8_t disc_number = 0;
  uint8_t disc_count = 0;
};

// Only the plain header. The name and icon sit in an XDBF resource inside the
// encrypted and compressed image, which is core work.
inline bool ReadXex(int fd, uint64_t base, uint64_t length, XexInfo* out) {
  constexpr uint32_t kExecutionInfoKey = 0x00040006;
  uint8_t head[0x18];
  if (length < sizeof(head) || !ReadAt(fd, base, head, sizeof(head))) {
    return false;
  }
  if (std::memcmp(head, "XEX2", 4) && std::memcmp(head, "XEX1", 4)) return false;
  const uint32_t header_size = Be32(head + 0x8);
  const uint32_t count = Be32(head + 0x14);
  if (header_size < sizeof(head) || header_size > length) return false;
  if (count > (header_size - sizeof(head)) / 8) return false;

  std::vector<uint8_t> table(size_t(count) * 8);
  if (count && !ReadAt(fd, base + sizeof(head), table.data(), table.size())) {
    return false;
  }
  for (uint32_t i = 0; i < count; ++i) {
    if (Be32(table.data() + i * 8) != kExecutionInfoKey) continue;
    const uint32_t offset = Be32(table.data() + i * 8 + 4);
    uint8_t info[0x18];
    if (uint64_t(offset) + sizeof(info) > header_size ||
        !ReadAt(fd, base + offset, info, sizeof(info))) {
      return false;
    }
    out->media_id = Be32(info + 0x0);
    out->title_id = Be32(info + 0xC);
    out->disc_number = info[0x12];
    out->disc_count = info[0x13];
    return true;
  }
  return false;
}

// --- XDVDFS: disc images ------------------------------------------------------

constexpr uint64_t kSectorSize = 2048;
constexpr uint64_t kDescriptorOffset = 32 * kSectorSize;
constexpr uint32_t kDescriptorTailMagic = 0x7EC;
constexpr char kDiscMagic[] = "MICROSOFT*XBOX*MEDIA";
constexpr size_t kDiscMagicSize = 20;
// Where a game partition starts. 0 is a stripped image; the rest sit behind a
// video partition. 0x18300000 is XGD1, an original Xbox redump. The others are
// the core's list, and Android's XGD2 and XGD3.
constexpr uint64_t kDiscOffsets[] = {
    0x00000000, 0x0000FB20, 0x00020600, 0x02080000, 0x0FD90000, 0x18300000,
};
constexpr uint32_t kMaxRootSize = 32 * 1024 * 1024;

struct Disc {
  uint64_t game_offset = 0;
  uint32_t root_sector = 0;
  uint32_t root_size = 0;
  bool tail_magic = false;  // Android's stricter test: both magics
};

inline bool FindDisc(int fd, uint64_t file_size, Disc* out) {
  for (const uint64_t offset : kDiscOffsets) {
    const uint64_t at = offset + kDescriptorOffset;
    uint8_t d[kDescriptorTailMagic + kDiscMagicSize];
    if (at + sizeof(d) > file_size || !ReadAt(fd, at, d, sizeof(d))) continue;
    if (std::memcmp(d, kDiscMagic, kDiscMagicSize)) continue;
    const uint32_t root_sector = Le32(d + 20);
    const uint32_t root_size = Le32(d + 24);
    if (root_size < 13 || root_size > kMaxRootSize) continue;
    out->game_offset = offset;
    out->root_sector = root_sector;
    out->root_size = root_size;
    out->tail_magic = !std::memcmp(d + kDescriptorTailMagic, kDiscMagic,
                                   kDiscMagicSize);
    return true;
  }
  return false;
}

// Finds a file in the root directory by name, ignoring case. The directory is a
// binary tree of 4-byte-aligned nodes; 0xFFFF on the left means the rest of the
// sector is padding, and the next node starts the next sector.
inline bool FindRootFile(int fd, uint64_t file_size, const Disc& disc,
                         const char* name, uint64_t* out_offset,
                         uint64_t* out_length) {
  const uint64_t root = disc.game_offset + disc.root_sector * kSectorSize;
  if (root + disc.root_size > file_size) return false;
  std::vector<uint8_t> dir(disc.root_size);
  if (!ReadAt(fd, root, dir.data(), dir.size())) return false;

  const size_t name_length = std::strlen(name);
  std::vector<uint32_t> pending{0};
  std::vector<bool> seen(dir.size() / 4 + 1, false);
  while (!pending.empty()) {
    const uint32_t ordinal = pending.back();
    pending.pop_back();
    const size_t at = size_t(ordinal) * 4;
    if (at + 14 > dir.size() || seen[ordinal]) continue;
    seen[ordinal] = true;
    const uint8_t* p = dir.data() + at;
    const uint16_t left = Le16(p);
    const uint16_t right = Le16(p + 2);
    if (left == 0xFFFF) {
      if (at % kSectorSize) {
        pending.push_back(
            uint32_t((at / kSectorSize + 1) * kSectorSize / 4));
      }
      continue;
    }
    const uint8_t length = p[13];
    if (at + 14 + length > dir.size()) continue;
    if (!(p[12] & 0x10) && length == name_length) {
      size_t i = 0;
      for (; i < length; ++i) {
        char a = static_cast<char>(p[14 + i]);
        char b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) break;
      }
      if (i == length) {
        const uint64_t offset =
            disc.game_offset + uint64_t(Le32(p + 4)) * kSectorSize;
        const uint64_t size = Le32(p + 8);
        if (offset + size > file_size) return false;
        *out_offset = offset;
        *out_length = size;
        return true;
      }
    }
    if (left) pending.push_back(left);
    if (right) pending.push_back(right);
  }
  return false;
}

// --- XBE ----------------------------------------------------------------------

struct XbeInfo {
  uint32_t title_id = 0;
  std::string title;
};

inline bool ReadXbe(int fd, uint64_t base, uint64_t length, XbeInfo* out) {
  constexpr size_t kOffBaseAddress = 0x104;
  constexpr size_t kOffCertificateAddress = 0x118;
  constexpr size_t kCertTitleId = 0x8;
  constexpr size_t kCertTitleName = 0xC;
  constexpr size_t kCertTitleUnits = 40;

  uint8_t head[kOffCertificateAddress + 4];
  if (length < sizeof(head) || !ReadAt(fd, base, head, sizeof(head))) {
    return false;
  }
  if (std::memcmp(head, "XBEH", 4)) return false;
  const uint32_t image_base = Le32(head + kOffBaseAddress);
  const uint32_t certificate = Le32(head + kOffCertificateAddress);
  if (certificate < image_base) return false;
  const uint64_t offset = certificate - image_base;
  uint8_t cert[kCertTitleName + kCertTitleUnits * 2];
  if (offset + sizeof(cert) > length ||
      !ReadAt(fd, base + offset, cert, sizeof(cert))) {
    return false;
  }
  out->title_id = Le32(cert + kCertTitleId);
  out->title = CleanTitle(
      Utf16ToUtf8(cert + kCertTitleName, kCertTitleUnits, false));
  return true;
}

}  // namespace probe
}  // namespace xenra

#endif  // XENRA_GAME_PROBE_HPP_
