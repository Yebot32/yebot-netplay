/**
 ******************************************************************************
 * Xenra : iOS shell - game list model (implementation)                        *
 ******************************************************************************
 */

#import "XenraGameScanner.h"

#import "XenraCovers.h"
#import "XenraGameProbe.hpp"
#import "XenraScreens.h"

#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <set>
#include <string>
#include <vector>

// A file iCloud has evicted. Reading it would start a download of the whole
// thing, and a scan must not do that. Not in the public headers on every SDK.
#ifndef SF_DATALESS
#define SF_DATALESS 0x40000000
#endif

namespace probe = xenra::probe;

namespace {

// GameLibraryRepository.MAX_SCAN_DEPTH.
constexpr int kMaxScanDepth = 12;

// Bumped when an entry's meaning changes; older cache files are ignored.
constexpr int kCacheVersion = 1;

std::string ToNative(NSString* path) {
  return path.length ? std::string(path.fileSystemRepresentation) : std::string();
}

NSString* FromNative(const std::string& path) {
  return [NSFileManager.defaultManager
      stringWithFileSystemRepresentation:path.c_str()
                                  length:path.size()];
}

NSString* FromUtf8(const std::string& text) {
  return text.empty() ? nil : [NSString stringWithUTF8String:text.c_str()];
}

std::string Lowercased(std::string text) {
  for (char& c : text) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c + 32);
  }
  return text;
}

std::string ExtensionOf(const std::string& lower_name) {
  const size_t dot = lower_name.rfind('.');
  return dot == std::string::npos ? std::string() : lower_name.substr(dot + 1);
}

// Hex, or nil: Android reads 00000000 as no id at all.
NSString* HexId(uint32_t value) {
  return value ? [NSString stringWithFormat:@"%08X", value] : nil;
}

// GameLibraryActivity.formatSize.
NSString* FormatSize(unsigned long long bytes) {
  static NSArray<NSString*>* const units = @[ @"B", @"KB", @"MB", @"GB", @"TB" ];
  double value = static_cast<double>(bytes);
  NSUInteger unit = 0;
  while (value >= 1024.0 && unit + 1 < units.count) {
    value /= 1024.0;
    ++unit;
  }
  return [NSString stringWithFormat:@"%.1f %@", value, units[unit]];
}

double ModificationTime(const struct stat& st) {
  return static_cast<double>(st.st_mtimespec.tv_sec) +
         static_cast<double>(st.st_mtimespec.tv_nsec) * 1e-9;
}

}  // namespace

// --- Entries ------------------------------------------------------------------

@interface XenraGameEntry ()
@property(nonatomic, readwrite, copy) NSString* path;
@property(nonatomic, readwrite, copy) NSString* name;
@property(nonatomic, readwrite, copy) NSString* subtitle;
@property(nonatomic, readwrite) unsigned long long fileSize;
@property(nonatomic, readwrite) XenraConsole console;
@property(nonatomic, readwrite) XenraGameFormat format;
@property(nonatomic, readwrite) XenraDiscLayout discLayout;
@property(nonatomic, readwrite, copy, nullable) NSString* titleId;
@property(nonatomic, readwrite, copy, nullable) NSString* mediaId;
@property(nonatomic, readwrite) NSInteger discNumber;
@property(nonatomic, readwrite) NSInteger discCount;
@property(nonatomic, readwrite) uint32_t contentType;
@property(nonatomic, readwrite, copy) NSString* fileName;
@property(nonatomic, readwrite, copy) NSString* fileTitle;
// The launch file's size and date, which say whether a cached read still holds.
@property(nonatomic) unsigned long long signatureSize;
@property(nonatomic) double signatureTime;
// Lowercased once, for the sort.
@property(nonatomic, copy) NSString* sortKey;
- (void)finish;
- (NSDictionary*)plist;
+ (nullable instancetype)entryFromPlist:(NSDictionary*)d;
@end

@implementation XenraGameEntry

- (NSArray<NSString*>*)contentPaths {
  switch (self.format) {
    case XenraGameFormatXEXFolder:
      return @[ self.path.stringByDeletingLastPathComponent ];
    case XenraGameFormatGOD:
      return @[ self.path, [self.path stringByAppendingString:@".data"] ];
    default:
      return @[ self.path ];
  }
}

- (nullable NSData*)embeddedIconData {
  if (self.format != XenraGameFormatGOD && self.format != XenraGameFormatSTFS) {
    return nil;
  }
  const int fd = open(self.path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) return nil;
  NSData* icon = nil;
  struct stat st;
  probe::ContainerInfo info;
  if (fstat(fd, &st) == 0 &&
      probe::ReadContainer(fd, static_cast<uint64_t>(st.st_size), &info) &&
      info.icon_size) {
    NSMutableData* bytes = [NSMutableData dataWithLength:info.icon_size];
    if (probe::ReadAt(fd, info.icon_offset, bytes.mutableBytes, info.icon_size)) {
      icon = bytes;
    }
  }
  close(fd);
  return icon;
}

- (void)finish {
  self.sortKey = self.name.lowercaseString;
  NSString* label;
  switch (self.format) {
    case XenraGameFormatGOD:
      label = @"GOD";
      break;
    case XenraGameFormatSTFS:
      label = @"STFS";
      break;
    case XenraGameFormatXEXFolder:
    case XenraGameFormatXEXFile:
      label = @"XEX";
      break;
    default:
      label = self.fileName.pathExtension.uppercaseString;
      break;
  }
  self.subtitle =
      self.fileSize
          ? [NSString stringWithFormat:@"Size: %@", FormatSize(self.fileSize)]
          : label;
}

- (BOOL)isEqual:(id)other {
  if (other == self) return YES;
  if (![other isKindOfClass:XenraGameEntry.class]) return NO;
  XenraGameEntry* entry = other;
  return [self.path isEqualToString:entry.path] &&
         [self.name isEqualToString:entry.name] &&
         self.signatureSize == entry.signatureSize &&
         self.signatureTime == entry.signatureTime &&
         self.format == entry.format;
}

- (NSUInteger)hash {
  return self.path.hash;
}

- (NSDictionary*)plist {
  NSMutableDictionary* d = [NSMutableDictionary dictionary];
  d[@"path"] = self.path;
  d[@"name"] = self.name;
  d[@"size"] = @(self.fileSize);
  d[@"console"] = @(self.console);
  d[@"format"] = @(self.format);
  d[@"layout"] = @(self.discLayout);
  d[@"titleId"] = self.titleId;
  d[@"mediaId"] = self.mediaId;
  d[@"discNumber"] = @(self.discNumber);
  d[@"discCount"] = @(self.discCount);
  d[@"contentType"] = @(self.contentType);
  d[@"fileName"] = self.fileName;
  d[@"fileTitle"] = self.fileTitle;
  d[@"signatureSize"] = @(self.signatureSize);
  d[@"signatureTime"] = @(self.signatureTime);
  return d;
}

+ (nullable instancetype)entryFromPlist:(NSDictionary*)d {
  NSString* path = d[@"path"];
  NSString* name = d[@"name"];
  NSString* fileName = d[@"fileName"];
  NSString* fileTitle = d[@"fileTitle"];
  if (![path isKindOfClass:NSString.class] ||
      ![name isKindOfClass:NSString.class] ||
      ![fileName isKindOfClass:NSString.class] ||
      ![fileTitle isKindOfClass:NSString.class]) {
    return nil;
  }
  XenraGameEntry* entry = [[XenraGameEntry alloc] init];
  entry.path = path;
  entry.name = name;
  entry.fileName = fileName;
  entry.fileTitle = fileTitle;
  entry.fileSize = [d[@"size"] unsignedLongLongValue];
  entry.console = static_cast<XenraConsole>([d[@"console"] integerValue]);
  entry.format = static_cast<XenraGameFormat>([d[@"format"] integerValue]);
  entry.discLayout = static_cast<XenraDiscLayout>([d[@"layout"] integerValue]);
  entry.titleId = d[@"titleId"];
  entry.mediaId = d[@"mediaId"];
  entry.discNumber = [d[@"discNumber"] integerValue];
  entry.discCount = [d[@"discCount"] integerValue];
  entry.contentType = [d[@"contentType"] unsignedIntValue];
  entry.signatureSize = [d[@"signatureSize"] unsignedLongLongValue];
  entry.signatureTime = [d[@"signatureTime"] doubleValue];
  [entry finish];
  return entry;
}

@end

// --- Reading one file ---------------------------------------------------------

namespace {

XenraGameEntry* NewEntry(NSString* path, const std::string& file_name,
                         const struct stat& st, XenraConsole console) {
  XenraGameEntry* entry = [[XenraGameEntry alloc] init];
  entry.path = path;
  entry.console = console;
  entry.fileName = FromNative(file_name);
  entry.fileSize = static_cast<unsigned long long>(st.st_size);
  entry.signatureSize = static_cast<unsigned long long>(st.st_size);
  entry.signatureTime = ModificationTime(st);
  return entry;
}

// An original Xbox file. isOgFile has already passed its extension.
XenraGameEntry* ReadOgFile(NSString* path, const std::string& file_name,
                           const struct stat& st) {
  XenraGameEntry* entry = NewEntry(path, file_name, st, XenraConsoleOG);
  bool tagged = false;
  const std::string title = probe::OgTitleFromFileName(file_name, &tagged);
  entry.fileTitle = FromUtf8(title) ?: entry.fileName;
  entry.name = entry.fileTitle;

  const std::string ext = ExtensionOf(Lowercased(file_name));
  if (ext != "iso" && ext != "xiso") {
    entry.format = XenraGameFormatCompressed;
    entry.discLayout = XenraDiscLayoutNotApplicable;
    [entry finish];
    return entry;
  }
  entry.format = XenraGameFormatDiscImage;
  entry.discLayout = XenraDiscLayoutUnknown;

  const int fd = (st.st_flags & SF_DATALESS)
                     ? -1
                     : open(path.fileSystemRepresentation, O_RDONLY);
  if (fd >= 0) {
    const uint64_t size = static_cast<uint64_t>(st.st_size);
    probe::Disc disc;
    if (probe::FindDisc(fd, size, &disc) && disc.tail_magic) {
      entry.discLayout = disc.game_offset == 0 ? XenraDiscLayoutXISO
                                               : XenraDiscLayoutRedump;
      uint64_t offset = 0;
      uint64_t length = 0;
      probe::XbeInfo xbe;
      if (probe::FindRootFile(fd, size, disc, "default.xbe", &offset, &length) &&
          probe::ReadXbe(fd, offset, length, &xbe)) {
        entry.titleId = HexId(xbe.title_id);
        NSString* real = FromUtf8(xbe.title);
        if (real && !tagged) entry.name = real;
      }
    }
    close(fd);
  }
  [entry finish];
  return entry;
}

// A file that has to be opened to know what it is.
XenraGameEntry* ReadContainerFile(NSString* path, const std::string& file_name,
                                  const struct stat& st) {
  if (st.st_flags & SF_DATALESS) return nil;
  const int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) return nil;
  probe::ContainerInfo info;
  const bool read =
      probe::ReadContainer(fd, static_cast<uint64_t>(st.st_size), &info);
  close(fd);
  if (!read || !probe::IsLaunchableContentType(info.content_type)) return nil;

  XenraGameEntry* entry = NewEntry(path, file_name, st, XenraConsole360);
  entry.format = info.svod ? XenraGameFormatGOD : XenraGameFormatSTFS;
  entry.fileTitle = entry.fileName;
  entry.name = FromUtf8(info.title_name) ?: FromUtf8(info.display_name)
                                                ?: entry.fileName;
  entry.titleId = HexId(info.title_id);
  entry.mediaId = HexId(info.media_id);
  entry.discNumber = info.disc_number;
  entry.discCount = info.disc_count;
  entry.contentType = info.content_type;
  if (info.svod) entry.fileSize += info.data_file_size;
  [entry finish];
  return entry;
}

void ApplyXex(XenraGameEntry* entry, const probe::XexInfo& xex) {
  entry.titleId = HexId(xex.title_id);
  entry.mediaId = HexId(xex.media_id);
  entry.discNumber = xex.disc_number;
  entry.discCount = xex.disc_count;
}

// A 360 disc image, .zar or loose .xex. The name is the file's: Android's comes
// from the XDBF resource when it can, and that needs the core.
XenraGameEntry* ReadPlain360File(NSString* path, const std::string& file_name,
                                 const struct stat& st, const std::string& ext) {
  XenraGameEntry* entry = NewEntry(path, file_name, st, XenraConsole360);
  entry.fileTitle = entry.fileName.stringByDeletingPathExtension;
  entry.name = entry.fileTitle;
  entry.format = ext == "zar"   ? XenraGameFormatZAR
                 : ext == "xex" ? XenraGameFormatXEXFile
                                : XenraGameFormatDiscImage;
  if (ext != "zar" && !(st.st_flags & SF_DATALESS)) {
    const int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
      const uint64_t size = static_cast<uint64_t>(st.st_size);
      probe::XexInfo xex;
      if (ext == "xex") {
        if (probe::ReadXex(fd, 0, size, &xex)) ApplyXex(entry, xex);
      } else {
        probe::Disc disc;
        uint64_t offset = 0;
        uint64_t length = 0;
        if (probe::FindDisc(fd, size, &disc) &&
            probe::FindRootFile(fd, size, disc, "default.xex", &offset, &length) &&
            probe::ReadXex(fd, offset, length, &xex)) {
          ApplyXex(entry, xex);
        }
      }
      close(fd);
    }
  }
  [entry finish];
  return entry;
}

XenraGameEntry* ReadXexFolder(NSString* xex_path, const std::string& folder_name,
                              const struct stat& st) {
  XenraGameEntry* entry = NewEntry(xex_path, "default.xex", st, XenraConsole360);
  entry.format = XenraGameFormatXEXFolder;
  entry.fileName = FromNative(folder_name);
  entry.fileTitle = entry.fileName;
  entry.name = entry.fileTitle;
  entry.fileSize = 0;
  if (!(st.st_flags & SF_DATALESS)) {
    const int fd = open(xex_path.fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
      probe::XexInfo xex;
      if (probe::ReadXex(fd, 0, static_cast<uint64_t>(st.st_size), &xex)) {
        ApplyXex(entry, xex);
      }
      close(fd);
    }
  }
  [entry finish];
  return entry;
}

bool IsOgFile(const std::string& lower_name) {
  const std::string ext = ExtensionOf(lower_name);
  return ext == "iso" || ext == "xiso" || ext == "cci" || ext == "cso";
}

bool IsContainerName(const std::string& lower_name) {
  // GameFormat.fromFileName: no dot at all. The named extensions are iOS only:
  // this shell has always listed them.
  if (lower_name.find('.') == std::string::npos) return true;
  const std::string ext = ExtensionOf(lower_name);
  return ext == "god" || ext == "con" || ext == "live" || ext == "pirs";
}

// One file as this console reads it, or nil.
XenraGameEntry* ReadFile(NSString* path, const std::string& file_name,
                         const struct stat& st, XenraConsole console) {
  const std::string lower = Lowercased(file_name);
  if (console == XenraConsoleOG) {
    return IsOgFile(lower) ? ReadOgFile(path, file_name, st) : nil;
  }
  const std::string ext = ExtensionOf(lower);
  if (ext == "iso" || ext == "zar" || ext == "xex") {
    return ReadPlain360File(path, file_name, st, ext);
  }
  return IsContainerName(lower) ? ReadContainerFile(path, file_name, st) : nil;
}

// Does this file need reading at all? Saves a dictionary lookup per stray file,
// and keeps a loose text file from ever being opened.
bool MightBeGame(const std::string& file_name, XenraConsole console) {
  const std::string lower = Lowercased(file_name);
  if (console == XenraConsoleOG) return IsOgFile(lower);
  const std::string ext = ExtensionOf(lower);
  return ext == "iso" || ext == "zar" || ext == "xex" || IsContainerName(lower);
}

}  // namespace

// --- The walk -----------------------------------------------------------------

@interface XenraScanToken : NSObject
- (void)cancel;
- (BOOL)isCancelled;
@end

@implementation XenraScanToken {
  std::atomic<bool> cancelled_;
}
- (void)cancel {
  cancelled_.store(true);
}
- (BOOL)isCancelled {
  return cancelled_.load();
}
@end

namespace {

struct Child {
  std::string name;
  struct stat st;
};

bool ListDirectory(const std::string& path, std::vector<Child>* out) {
  DIR* dir = opendir(path.c_str());
  if (!dir) return false;
  while (struct dirent* item = readdir(dir)) {
    const std::string name = item->d_name;
    if (name.empty() || name[0] == '.') continue;  // ".", "..", hidden, "._x"
    Child child;
    child.name = name;
    // stat, not lstat: a link to a folder is followed, and the visited set is
    // what stops a loop. A dangling link fails here and is skipped.
    if (stat((path + "/" + name).c_str(), &child.st) == 0) {
      out->push_back(std::move(child));
    }
  }
  closedir(dir);
  return true;
}

std::string Canonical(const std::string& path) {
  char resolved[PATH_MAX];
  return realpath(path.c_str(), resolved) ? std::string(resolved) : std::string();
}

struct Scan {
  XenraConsole console;
  XenraScanToken* token;
  // What earlier scans read, by path. A file with the same size and date is
  // not opened again. Survives a cancelled scan, so a restart keeps its work.
  NSMutableDictionary<NSString*, XenraGameEntry*>* memo;
  NSMutableArray<XenraGameEntry*>* found;
  std::set<std::string> visited;
};

void AddEntry(Scan& scan, XenraGameEntry* entry) {
  if (!entry) return;
  scan.memo[entry.path] = entry;
  [scan.found addObject:entry];
}

XenraGameEntry* Remembered(Scan& scan, NSString* path, const struct stat& st) {
  XenraGameEntry* known = scan.memo[path];
  return known && known.console == scan.console &&
                 known.signatureSize ==
                     static_cast<unsigned long long>(st.st_size) &&
                 known.signatureTime == ModificationTime(st)
             ? known
             : nil;
}

// GameLibraryRepository.collectGames.
void Collect(Scan& scan, const std::string& dir,
             const std::vector<Child>& children, int depth) {
  for (const Child& child : children) {
    if (scan.token.isCancelled) return;
    const std::string path = dir + "/" + child.name;

    if (S_ISREG(child.st.st_mode)) {
      if (!MightBeGame(child.name, scan.console)) continue;
      NSString* native = FromNative(path);
      if (!native) continue;
      XenraGameEntry* known = Remembered(scan, native, child.st);
      AddEntry(scan, known ?: ReadFile(native, child.name, child.st, scan.console));
      continue;
    }
    if (!S_ISDIR(child.st.st_mode)) continue;

    // A GOD payload holds extensionless Data#### files, each of which would be
    // probed as a container.
    if (scan.console == XenraConsole360) {
      const std::string lower = Lowercased(child.name);
      if (lower.size() >= 5 && !lower.compare(lower.size() - 5, 5, ".data")) {
        continue;
      }
    }

    std::vector<Child> entries;
    if (!ListDirectory(path, &entries)) continue;

    if (scan.console == XenraConsole360) {
      // A folder holding default.xex IS the game; below it is game data.
      const Child* xex = nullptr;
      for (const Child& entry : entries) {
        if (S_ISREG(entry.st.st_mode) &&
            Lowercased(entry.name) == "default.xex") {
          xex = &entry;
          break;
        }
      }
      if (xex) {
        NSString* native = FromNative(path + "/" + xex->name);
        if (!native) continue;
        XenraGameEntry* known = Remembered(scan, native, xex->st);
        AddEntry(scan, known ?: ReadXexFolder(native, child.name, xex->st));
        continue;
      }
    }

    if (depth >= kMaxScanDepth) continue;
    const std::string canonical = Canonical(path);
    if (canonical.empty() || !scan.visited.insert(canonical).second) continue;
    Collect(scan, path, entries, depth + 1);
  }
}

// nil when cancelled. Sorted; see the header.
NSArray<XenraGameEntry*>* ScanFolders(
    NSArray<NSString*>* roots, XenraConsole console, XenraScanToken* token,
    NSMutableDictionary<NSString*, XenraGameEntry*>* memo,
    NSMutableArray<NSString*>* unreadable) {
  Scan scan{console, token, memo, [NSMutableArray array], {}};
  for (NSString* root in roots) {
    const std::string path = ToNative(root);
    if (path.empty()) continue;
    std::vector<Child> children;
    if (!ListDirectory(path, &children)) {
      [unreadable addObject:root];
      continue;
    }
    // Two roots can overlap: the first to reach a folder keeps it.
    const std::string canonical = Canonical(path);
    if (canonical.empty() || !scan.visited.insert(canonical).second) continue;
    Collect(scan, path, children, 1);
    if (token.isCancelled) return nil;
  }

  NSMutableSet<NSString*>* seen = [NSMutableSet setWithCapacity:scan.found.count];
  for (XenraGameEntry* entry in scan.found) [seen addObject:entry.path];
  for (NSString* path in memo.allKeys) {
    if (![seen containsObject:path]) [memo removeObjectForKey:path];
  }

  [scan.found sortUsingComparator:^NSComparisonResult(XenraGameEntry* a,
                                                      XenraGameEntry* b) {
    const NSComparisonResult order =
        [a.sortKey compare:b.sortKey options:NSLiteralSearch];
    return order != NSOrderedSame ? order
                                  : [a.path compare:b.path options:NSLiteralSearch];
  }];
  return [scan.found copy];
}

NSString* CacheFile(XenraConsole console) {
  NSString* caches = NSSearchPathForDirectoriesInDomains(
                         NSCachesDirectory, NSUserDomainMask, YES)
                         .firstObject;
  NSString* dir = [caches stringByAppendingPathComponent:@"XenraLibrary"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  return [dir stringByAppendingPathComponent:console == XenraConsoleOG
                                                 ? @"games-og.plist"
                                                 : @"games-360.plist"];
}

// The list on disk is only worth having for the folders it came from. Paths
// also move when an update gives the app a new container.
NSArray<XenraGameEntry*>* LoadCache(XenraConsole console, NSArray<NSString*>* roots) {
  NSData* data = [NSData dataWithContentsOfFile:CacheFile(console)];
  if (!data) return @[];
  NSDictionary* root = [NSPropertyListSerialization propertyListWithData:data
                                                                 options:0
                                                                  format:nil
                                                                   error:nil];
  if (![root isKindOfClass:NSDictionary.class] ||
      [root[@"version"] integerValue] != kCacheVersion ||
      ![root[@"roots"] isEqual:roots] ||
      ![root[@"games"] isKindOfClass:NSArray.class]) {
    return @[];
  }
  NSMutableArray<XenraGameEntry*>* games = [NSMutableArray array];
  for (NSDictionary* item in root[@"games"]) {
    if (![item isKindOfClass:NSDictionary.class]) continue;
    if (XenraGameEntry* entry = [XenraGameEntry entryFromPlist:item]) {
      [games addObject:entry];
    }
  }
  return games;
}

void SaveCache(XenraConsole console, NSArray<NSString*>* roots,
               NSArray<XenraGameEntry*>* games) {
  NSMutableArray* items = [NSMutableArray arrayWithCapacity:games.count];
  for (XenraGameEntry* entry in games) [items addObject:entry.plist];
  NSData* data = [NSPropertyListSerialization
      dataWithPropertyList:@{
        @"version" : @(kCacheVersion),
        @"roots" : roots,
        @"games" : items
      }
                    format:NSPropertyListBinaryFormat_v1_0
                   options:0
                     error:nil];
  [data writeToFile:CacheFile(console) atomically:YES];
}

}  // namespace

// --- The shared list ----------------------------------------------------------

typedef void (^XenraRefreshBlock)(NSArray<XenraGameEntry*>* games, BOOL changed);

// Main thread, except memo_, which belongs to queue_.
@interface XenraLibraryStore : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) BOOL scanning;
@property(nonatomic, readonly) NSArray<NSString*>* unreadable;
- (NSArray<XenraGameEntry*>*)games;
- (void)refresh:(XenraRefreshBlock)completion;
- (void)cancel;
- (void)deleteGame:(XenraGameEntry*)game completion:(void (^)(BOOL))completion;
@end

@implementation XenraLibraryStore {
  dispatch_queue_t queue_;
  NSMutableDictionary<NSString*, XenraGameEntry*>* memo_;
  NSMutableDictionary<NSNumber*, NSArray<XenraGameEntry*>*>* lists_;
  NSMutableDictionary<NSNumber*, NSArray<NSString*>*>* savedRoots_;
  XenraScanToken* active_;
  NSMutableArray<XenraRefreshBlock>* waiters_;
}

+ (instancetype)shared {
  static XenraLibraryStore* store;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    store = [[XenraLibraryStore alloc] init];
  });
  return store;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
    queue_ = dispatch_queue_create("xenra.library.scan", attr);
    memo_ = [NSMutableDictionary dictionary];
    lists_ = [NSMutableDictionary dictionary];
    savedRoots_ = [NSMutableDictionary dictionary];
    waiters_ = [NSMutableArray array];
    _unreadable = @[];
  }
  return self;
}

- (BOOL)scanning {
  return active_ != nil;
}

// The list for a console, loading it from disk the first time.
- (NSArray<XenraGameEntry*>*)listFor:(XenraConsole)console
                               roots:(NSArray<NSString*>*)roots {
  NSArray<XenraGameEntry*>* list = lists_[@(console)];
  if (!list) {
    list = LoadCache(console, roots);
    lists_[@(console)] = list;
    if (list.count) savedRoots_[@(console)] = roots;
  }
  return list;
}

- (NSArray<XenraGameEntry*>*)games {
  const XenraConsole console = [XenraSettings console];
  NSArray<XenraGameEntry*>* list = lists_[@(console)];
  return list ?: [self listFor:console roots:[XenraSettings gameFolders]];
}

- (void)refresh:(XenraRefreshBlock)completion {
  // gameFolders is read here, on the main thread, and never from the scan.
  const XenraConsole console = [XenraSettings console];
  NSArray<NSString*>* roots = [XenraSettings gameFolders];
  NSArray<XenraGameEntry*>* known = [self listFor:console roots:roots];

  if (completion) [waiters_ addObject:[completion copy]];
  [active_ cancel];
  XenraScanToken* token = [[XenraScanToken alloc] init];
  active_ = token;

  NSMutableDictionary* memo = memo_;
  dispatch_async(queue_, ^{
    if (token.isCancelled) return;
    for (XenraGameEntry* entry in known) {
      if (!memo[entry.path]) memo[entry.path] = entry;
    }
    NSMutableArray<NSString*>* unreadable = [NSMutableArray array];
    NSArray<XenraGameEntry*>* fresh =
        ScanFolders(roots, console, token, memo, unreadable);
    if (!fresh) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finish:token
           console:console
             roots:roots
             fresh:fresh
        unreadable:unreadable];
    });
  });
}

- (void)finish:(XenraScanToken*)token
       console:(XenraConsole)console
         roots:(NSArray<NSString*>*)roots
         fresh:(NSArray<XenraGameEntry*>*)fresh
    unreadable:(NSArray<NSString*>*)unreadable {
  // A newer refresh or a cancel took over, and the waiters went with it.
  if (token != active_) return;
  active_ = nil;

  const BOOL changed = ![fresh isEqualToArray:lists_[@(console)] ?: @[]];
  lists_[@(console)] = fresh;
  _unreadable = [unreadable copy];

  if (changed || ![savedRoots_[@(console)] isEqual:roots]) {
    savedRoots_[@(console)] = roots;
    dispatch_async(queue_, ^{
      SaveCache(console, roots, fresh);
    });
  }
  [self fire:fresh changed:changed];
}

- (void)fire:(NSArray<XenraGameEntry*>*)games changed:(BOOL)changed {
  NSArray<XenraRefreshBlock>* waiters = [waiters_ copy];
  [waiters_ removeAllObjects];
  for (XenraRefreshBlock waiter in waiters) waiter(games, changed);
}

- (void)cancel {
  if (!active_) return;
  [active_ cancel];
  active_ = nil;
  [self fire:[self games] changed:NO];
}

// Strictly inside one of the roots, once links are resolved.
static BOOL InsideRoots(const std::string& target,
                        const std::vector<std::string>& roots) {
  for (const std::string& root : roots) {
    if (target.size() > root.size() + 1 &&
        !target.compare(0, root.size(), root) && target[root.size()] == '/') {
      return YES;
    }
  }
  return NO;
}

- (void)deleteGame:(XenraGameEntry*)game completion:(void (^)(BOOL))completion {
  const XenraConsole console = [XenraSettings console];
  NSArray<NSString*>* roots = [XenraSettings gameFolders];
  dispatch_async(queue_, ^{
    std::vector<std::string> canonical_roots;
    for (NSString* root in roots) {
      const std::string path = Canonical(ToNative(root));
      if (!path.empty()) canonical_roots.push_back(path);
    }
    BOOL fenced = YES;
    NSFileManager* fm = NSFileManager.defaultManager;
    for (NSString* path in game.contentPaths) {
      if (![fm fileExistsAtPath:path]) continue;
      if (!InsideRoots(Canonical(ToNative(path)), canonical_roots)) fenced = NO;
    }
    BOOL deleted = NO;
    if (fenced) {
      NSArray<NSString*>* paths = game.contentPaths;
      // The launch target decides success, and a .data folder that was never
      // there is not a failure.
      deleted = [fm removeItemAtPath:paths.firstObject error:nil];
      for (NSUInteger i = 1; i < paths.count; ++i) {
        [fm removeItemAtPath:paths[i] error:nil];
      }
    }
    if (deleted) [self->memo_ removeObjectForKey:game.path];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (deleted) {
        NSMutableArray<XenraGameEntry*>* list =
            [self->lists_[@(console)] mutableCopy];
        [list removeObject:game];
        if (list) {
          NSArray<XenraGameEntry*>* rest = [list copy];
          self->lists_[@(console)] = rest;
          dispatch_async(self->queue_, ^{
            SaveCache(console, roots, rest);
          });
        }
      }
      if (completion) completion(deleted);
    });
  });
}

@end

// --- The public face ----------------------------------------------------------

@implementation XenraGameScanner

+ (instancetype)shared {
  static XenraGameScanner* scanner;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    scanner = [[XenraGameScanner alloc] init];
  });
  return scanner;
}

- (NSArray<XenraGameEntry*>*)cachedGames {
  return [XenraLibraryStore.shared games];
}

- (BOOL)isScanning {
  return XenraLibraryStore.shared.scanning;
}

- (NSArray<NSString*>*)unreadableFolders {
  return XenraLibraryStore.shared.unreadable;
}

- (void)refreshWithCompletion:(void (^)(NSArray<XenraGameEntry*>*, BOOL))completion {
  [XenraLibraryStore.shared refresh:completion];
}

- (void)cancel {
  [XenraLibraryStore.shared cancel];
}

- (void)deleteGame:(XenraGameEntry*)game completion:(void (^)(BOOL))completion {
  [XenraLibraryStore.shared deleteGame:game completion:completion];
}

+ (XenraGameEntry*)entryForFileAtPath:(NSString*)path console:(XenraConsole)console {
  struct stat st;
  if (stat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) {
    return nil;
  }
  return ReadFile(path, ToNative(path.lastPathComponent), st, console);
}

@end

// --- Self-test ----------------------------------------------------------------

#ifdef XENRA_UITEST

namespace {

struct Bytes {
  std::vector<uint8_t> data;
  explicit Bytes(size_t size) : data(size, 0) {}
  void Text(size_t at, const char* text) {
    memcpy(data.data() + at, text, strlen(text));
  }
  void Be32(size_t at, uint32_t v) {
    for (int i = 0; i < 4; ++i) data[at + i] = uint8_t(v >> (24 - i * 8));
  }
  void Le32(size_t at, uint32_t v) {
    for (int i = 0; i < 4; ++i) data[at + i] = uint8_t(v >> (i * 8));
  }
  void Utf16(size_t at, const char* text, bool big_endian) {
    for (size_t i = 0; text[i]; ++i) {
      data[at + i * 2 + (big_endian ? 1 : 0)] = uint8_t(text[i]);
    }
  }
};

void Put(NSString* path, const Bytes& bytes, off_t at = 0) {
  [NSFileManager.defaultManager
            createDirectoryAtPath:path.stringByDeletingLastPathComponent
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  const int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT, 0644);
  if (fd < 0) return;
  pwrite(fd, bytes.data.data(), bytes.data.size(), at);
  close(fd);
}

Bytes Container(const char* magic, uint32_t type, uint32_t volume,
                const char* title, const char* display, uint32_t title_id) {
  Bytes b(probe::kContainerHeaderSize);
  b.Text(0, magic);
  b.Be32(probe::kOffContentType, type);
  b.Be32(probe::kOffContentType + 4, 2);
  b.Be32(probe::kOffExecutionInfo + 0xC, title_id);
  b.Be32(probe::kOffVolumeType, volume);
  if (title) b.Utf16(probe::kOffTitleName, title, true);
  if (display) b.Utf16(probe::kOffDisplayName, display, true);
  return b;
}

Bytes Xex(uint32_t title_id) {
  Bytes b(0x100);
  b.Text(0, "XEX2");
  b.Be32(0x8, 0x100);
  b.Be32(0x14, 1);
  b.Be32(0x18, 0x00040006);
  b.Be32(0x1C, 0x40);
  b.Be32(0x40 + 0xC, title_id);
  return b;
}

Bytes Xbe(uint32_t title_id, const char* title) {
  Bytes b(0x500);
  b.Text(0, "XBEH");
  b.Le32(0x104, 0x10000);
  b.Le32(0x118, 0x10400);
  b.Le32(0x400 + 0x8, title_id);
  b.Utf16(0x400 + 0xC, title, false);
  return b;
}

// A one-file XDVDFS volume whose partition starts at game_offset.
void PutDisc(NSString* path, uint64_t game_offset, const char* file,
             const Bytes& content) {
  constexpr uint32_t kRootSector = 33;
  constexpr uint32_t kFileSector = 40;
  Bytes descriptor(0x800);
  descriptor.Text(0, probe::kDiscMagic);
  descriptor.Le32(20, kRootSector);
  descriptor.Le32(24, 2048);
  descriptor.Text(probe::kDescriptorTailMagic, probe::kDiscMagic);
  Put(path, descriptor, off_t(game_offset + probe::kDescriptorOffset));

  Bytes root(2048);
  root.Le32(4, kFileSector);
  root.Le32(8, uint32_t(content.data.size()));
  root.data[12] = 0x20;
  root.data[13] = uint8_t(strlen(file));
  root.Text(14, file);
  // The rest of the sector is padding.
  memset(root.data.data() + 32, 0xFF, 2048 - 32);
  Put(path, root, off_t(game_offset + kRootSector * probe::kSectorSize));

  Put(path, content, off_t(game_offset + kFileSector * probe::kSectorSize));
}

}  // namespace

void XenraScannerSelfTest(void) {
  __block int passed = 0;
  __block int failed = 0;
  void (^check)(NSString*, BOOL) = ^(NSString* name, BOOL ok) {
    ok ? ++passed : ++failed;
    XenraLog([NSString stringWithFormat:@"selftest %@: %@", ok ? @"PASS" : @"FAIL",
                                        name]);
  };

  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* base = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"xenra-selftest-%d", getpid()]];
  [fm removeItemAtPath:base error:nil];
  NSString* x360 = [base stringByAppendingPathComponent:@"360"];
  NSString* og = [base stringByAppendingPathComponent:@"og"];
  NSString* (^in360)(NSString*) = ^(NSString* p) {
    return [x360 stringByAppendingPathComponent:p];
  };
  NSString* (^inOg)(NSString*) = ^(NSString* p) {
    return [og stringByAppendingPathComponent:p];
  };

  // Xbox 360.
  Put(in360(@"god/4D5307E6/00007000/ABCDEF0123"),
      Container("LIVE", 0x7000, 1, "Halo Test", "Display Only", 0x4D5307E6));
  Put(in360(@"god/4D5307E6/00007000/ABCDEF0123.data/Data0000"),
      Container("LIVE", 0x7000, 1, "Payload Must Not List", nullptr, 1));
  Put(in360(@"a/b/c/ArcadeFile"),
      Container("CON ", 0xD0000, 0, nullptr, "Arcade Display", 0x58410001));
  Put(in360(@"PirsGame"),
      Container("PIRS", 0x7000, 1, nullptr, nullptr, 0x58410002));
  Put(in360(@"dlc/SomeDlc"), Container("LIVE", 0x2, 0, "DLC Must Not List",
                                       nullptr, 0x58410003));
  Put(in360(@"update/SomeUpdate"), Container("LIVE", 0xB0000, 0,
                                             "Update Must Not List", nullptr,
                                             0x58410004));
  {
    Bytes shortFile(100);
    shortFile.Text(0, "LIVE");
    Put(in360(@"TruncatedContainer"), shortFile);
    Bytes junk(0x9800);
    junk.Text(0, "JUNK");
    Put(in360(@"JunkFile"), junk);
    Put(in360(@"readme.txt"), Bytes(16));
    Put(in360(@"Game.zar"), Bytes(16));
    Put(in360(@".hidden/Hidden.iso"), Bytes(16));
    Put(in360(@"._AppleDouble.iso"), Bytes(16));
  }
  Put(in360(@"Folder Game/default.xex"), Xex(0x41560001));
  Put(in360(@"Folder Game/data/Nested.iso"), Bytes(16));
  Put(in360(@"deep/er/UPPER/DEFAULT.XEX"), Xex(0x41560002));
  Put(in360(@"Loose.xex"), Xex(0x41560003));
  PutDisc(in360(@"Disc Game.iso"), 0x02080000, "default.xex", Xex(0x41560004));
  Put(in360(@"Odd Name.iso"), Bytes(16));
  [fm createSymbolicLinkAtPath:in360(@"a/b/loop")
           withDestinationPath:x360
                         error:nil];

  // Depth: a file at depth 12 is found, one at 13 is not.
  NSMutableString* levels = [NSMutableString string];
  for (int i = 1; i <= 11; ++i) [levels appendFormat:@"%d/", i];
  Put(in360([levels stringByAppendingString:@"At Limit.iso"]), Bytes(16));
  Put(in360([levels stringByAppendingString:@"12/Past Limit.iso"]), Bytes(16));

  // Original Xbox.
  PutDisc(inOg(@"sub/hand-named.xiso"), 0, "default.xbe",
          Xbe(0x4D530064, "Real Title"));
  PutDisc(inOg(@"Tagged Long Title (USA).iso"), 0, "default.xbe",
          Xbe(0x4D530065, "Tagged: tLT"));
  PutDisc(inOg(@"redump.iso"), 0x18300000, "DEFAULT.XBE",
          Xbe(0x4D530066, "Redump Title"));
  Put(inOg(@"folder (World) (En,Fr)/Set (World) (En,Fr).xiso.iso"), Bytes(16));
  Put(inOg(@"Compressed.cci"), Bytes(16));
  Put(inOg(@"apple.iso"), Bytes(16));
  Put(inOg(@"Banana.iso"), Bytes(16));
  Put(inOg(@"cherry.iso"), Bytes(16));
  Put(inOg(@"Loose.xex"), Xex(1));
  Put(inOg(@"ContainerFile"), Container("LIVE", 0x7000, 1, "No", nullptr, 1));

  XenraScanToken* token = [[XenraScanToken alloc] init];
  NSMutableDictionary* memo = [NSMutableDictionary dictionary];
  NSMutableArray* unreadable = [NSMutableArray array];
  NSArray<XenraGameEntry*>* found =
      ScanFolders(@[ x360 ], XenraConsole360, token, memo, unreadable);
  XenraGameEntry* (^named)(NSArray<XenraGameEntry*>*, NSString*) =
      ^XenraGameEntry*(NSArray<XenraGameEntry*>* list, NSString* name) {
        for (XenraGameEntry* entry in list) {
          if ([entry.name isEqualToString:name]) return entry;
        }
        return nil;
      };
  NSArray<NSString*>* (^names)(NSArray<XenraGameEntry*>*) =
      ^NSArray<NSString*>*(NSArray<XenraGameEntry*>* list) {
        return [list valueForKey:@"name"];
      };
  XenraLog([NSString stringWithFormat:@"selftest 360 found: %@",
                                      [names(found) componentsJoinedByString:@" | "]]);

  XenraGameEntry* god = named(found, @"Halo Test");
  check(@"LIVE, SVOD: GOD with title, id and data folder",
        god.format == XenraGameFormatGOD &&
            [god.titleId isEqualToString:@"4D5307E6"] &&
            god.contentPaths.count == 2 &&
            [god.contentPaths[1] hasSuffix:@"ABCDEF0123.data"]);
  XenraGameEntry* arcade = named(found, @"Arcade Display");
  check(@"CON, STFS: display name when the title is blank, found 3 deep",
        arcade.format == XenraGameFormatSTFS && arcade.contentType == 0xD0000);
  check(@"PIRS with no names falls back to the file name",
        named(found, @"PirsGame").format == XenraGameFormatGOD);
  check(@"add-on content, short files and junk do not list",
        !named(found, @"DLC Must Not List") &&
            !named(found, @"Update Must Not List") &&
            !named(found, @"TruncatedContainer") && !named(found, @"JunkFile"));
  check(@"a .data payload is not scanned",
        !named(found, @"Payload Must Not List") && !named(found, @"Data0000"));
  XenraGameEntry* folder = named(found, @"Folder Game");
  check(@"XEX folder: launches default.xex, deletes the folder",
        folder.format == XenraGameFormatXEXFolder &&
            [folder.path hasSuffix:@"Folder Game/default.xex"] &&
            [folder.contentPaths.firstObject hasSuffix:@"Folder Game"] &&
            [folder.titleId isEqualToString:@"41560001"]);
  check(@"nothing under a XEX folder lists", !named(found, @"Nested"));
  check(@"DEFAULT.XEX in any case makes a folder a game",
        named(found, @"UPPER").format == XenraGameFormatXEXFolder);
  check(@"loose .xex", named(found, @"Loose").format == XenraGameFormatXEXFile &&
                           [named(found, @"Loose").titleId isEqualToString:@"41560003"]);
  check(@"360 ISO behind a video partition gives its title id",
        [named(found, @"Disc Game").titleId isEqualToString:@"41560004"]);
  check(@"an unreadable ISO still lists, with no id",
        named(found, @"Odd Name") && !named(found, @"Odd Name").titleId);
  check(@".zar lists", named(found, @"Game").format == XenraGameFormatZAR);
  check(@"hidden files and folders do not list",
        !named(found, @"Hidden") && !named(found, @"._AppleDouble"));
  check(@"depth limit: 12 yes, 13 no",
        named(found, @"At Limit") && !named(found, @"Past Limit"));
  NSUInteger arcadeCount = 0;
  for (XenraGameEntry* entry in found) {
    if ([entry.name isEqualToString:@"Arcade Display"]) ++arcadeCount;
  }
  check(@"a symlink loop ends, and lists nothing twice", arcadeCount == 1);

  NSArray<XenraGameEntry*>* again =
      ScanFolders(@[ x360 ], XenraConsole360, token, memo, unreadable);
  BOOL sameObjects = again.count == found.count;
  for (NSUInteger i = 0; sameObjects && i < found.count; ++i) {
    sameObjects = again[i] == found[i];
  }
  check(@"a second scan reads no file again", sameObjects);
  check(@"an unchanged tree compares equal", [again isEqualToArray:found]);

  usleep(20000);
  Put(in360(@"Disc Game.iso"), Xex(0x41560004), 0x400);
  NSArray<XenraGameEntry*>* touched =
      ScanFolders(@[ x360 ], XenraConsole360, token, memo, unreadable);
  check(@"a rewritten file is read again, and compares different",
        named(touched, @"Disc Game") != named(found, @"Disc Game") &&
            ![touched isEqualToArray:found]);

  XenraScanToken* stopped = [[XenraScanToken alloc] init];
  [stopped cancel];
  check(@"a cancelled scan gives nil",
        ScanFolders(@[ x360 ], XenraConsole360, stopped, memo, unreadable) == nil);

  NSMutableArray* lost = [NSMutableArray array];
  ScanFolders(@[ [base stringByAppendingPathComponent:@"gone"] ], XenraConsole360,
              token, [NSMutableDictionary dictionary], lost);
  check(@"a missing folder is reported", lost.count == 1);

  NSArray<XenraGameEntry*>* ogFound = ScanFolders(
      @[ og, og ], XenraConsoleOG, token, [NSMutableDictionary dictionary],
      [NSMutableArray array]);
  XenraLog([NSString stringWithFormat:@"selftest OG found: %@",
                                      [names(ogFound) componentsJoinedByString:@" | "]]);
  XenraGameEntry* real = named(ogFound, @"Real Title");
  check(@"XISO in a subfolder: certificate title and id",
        [real.titleId isEqualToString:@"4D530064"] &&
            [real.fileTitle isEqualToString:@"hand-named"] &&
            real.discLayout == XenraDiscLayoutXISO);
  XenraGameEntry* tagged = named(ogFound, @"Tagged Long Title");
  check(@"a tagged file keeps its name, and still gets the id",
        [tagged.titleId isEqualToString:@"4D530065"]);
  XenraGameEntry* redump = named(ogFound, @"Redump Title");
  check(@"redump layout at XGD1 is seen", redump.discLayout == XenraDiscLayoutRedump);
  check(@".xiso.iso and two tags come off",
        named(ogFound, @"Set").discLayout == XenraDiscLayoutUnknown);
  check(@".cci lists as compressed",
        named(ogFound, @"Compressed").format == XenraGameFormatCompressed);
  check(@"no 360 formats in the OG list",
        !named(ogFound, @"Loose") && !named(ogFound, @"No") &&
            !named(ogFound, @"ContainerFile"));
  check(@"the same folder twice lists once", ogFound.count == 8);
  NSArray* order = names(ogFound);
  check(@"sorted by lowercased title",
        [order indexOfObject:@"apple"] < [order indexOfObject:@"Banana"] &&
            [order indexOfObject:@"Banana"] < [order indexOfObject:@"cherry"]);

  XenraGameEntry* one = [XenraGameScanner entryForFileAtPath:in360(@"PirsGame")
                                                     console:XenraConsole360];
  check(@"one file reads as a game", one.format == XenraGameFormatGOD);
  check(@"one add-on file reads as nothing",
        ![XenraGameScanner entryForFileAtPath:in360(@"dlc/SomeDlc")
                                      console:XenraConsole360]);

  XenraGameEntry* plist = [XenraGameEntry entryFromPlist:god.plist];
  check(@"an entry survives the disk cache",
        [plist isEqual:god] && [plist.subtitle isEqualToString:god.subtitle] &&
            [plist.titleId isEqualToString:god.titleId]);

  XenraCoversSelfTest(check);

  [fm removeItemAtPath:base error:nil];
  XenraLog([NSString stringWithFormat:@"selftest scanner: %d passed, %d failed",
                                      passed, failed]);

  // The shared path, on the real folders. Completions need the main queue, so
  // these land after this function returns.
  dispatch_async(dispatch_get_main_queue(), ^{
    XenraGameScanner* scanner = XenraGameScanner.shared;
    [scanner refreshWithCompletion:^(NSArray<XenraGameEntry*>* first, BOOL c1) {
      [scanner refreshWithCompletion:^(NSArray<XenraGameEntry*>* second, BOOL c2) {
        check(@"refresh: nothing changed the second time",
              !c2 && [second isEqualToArray:first] &&
                  [scanner.cachedGames isEqualToArray:second]);
        __block int calls = 0;
        [scanner refreshWithCompletion:^(NSArray* games, BOOL changed) {
          ++calls;
          check(@"cancel: completion runs at once, with no change", !changed);
        }];
        [scanner cancel];
        check(@"cancel: exactly one completion, and not scanning",
              calls == 1 && !scanner.scanning);
        XenraLog([NSString stringWithFormat:@"selftest all: %d passed, %d failed",
                                            passed, failed]);
      }];
    }];
  });
}

#endif  // XENRA_UITEST
