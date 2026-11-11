#import "XenraInsignia.h"

#include <string.h>

#import "XenraScreens.h"
#import "XenraSettings.h"
#import "XenraStrings.h"
#import "XenraXemu.h"

NSString* const XenraInsigniaPrimaryDNS = @"46.101.64.175";
NSString* const XenraInsigniaSecondaryDNS = @"8.8.8.8";

static NSString* const kSetupDiscKey = @"insignia.setupDisc";
static NSString* const kSignedUpKey = @"insignia.signedUp";
static NSString* const kDashboardFolder = @"xemu/dashboard";

static const NSUInteger kEepromSize = 256;
static const NSUInteger kUserChecksumOffset = 0x60;
static const NSUInteger kUserChecksumStart = 0x64;
static const NSUInteger kUserChecksumLength = 0x5C;
static const NSUInteger kXboxLiveDNSOffset = 0xAC;

NSString* XenraInsigniaSiteURL(void) { return @"https://insignia.live"; }
NSString* XenraInsigniaGuideURL(void) { return @"https://insignia.live/guide/connect"; }
NSString* XenraInsigniaSetupDownloadURL(void) {
  return @"https://github.com/insignia-live/setup-assistant-release/releases/latest";
}

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                             NSUserDomainMask, YES)
      .firstObject;
}

// --- EEPROM -----------------------------------------------------------------

static uint32_t ReadLE32(const uint8_t* p) {
  return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
         ((uint32_t)p[3] << 24);
}

static void WriteLE32(uint8_t* p, uint32_t value) {
  p[0] = (uint8_t)(value & 0xFF);
  p[1] = (uint8_t)((value >> 8) & 0xFF);
  p[2] = (uint8_t)((value >> 16) & 0xFF);
  p[3] = (uint8_t)((value >> 24) & 0xFF);
}

// XboxEepromEditor.xboxChecksum, unchanged: a 32-bit carry accumulator over
// 32-bit little-endian words, inverted. The EEPROM's user block runs 0x64..0xBF
// and includes the DNS bytes, so this must run after they are written.
static uint32_t XboxChecksum(const uint8_t* data, NSUInteger offset,
                             NSUInteger length) {
  uint32_t high = 0;
  uint32_t low = 0;
  for (NSUInteger pos = offset; pos < offset + length; pos += 4) {
    const uint32_t value = ReadLE32(data + pos);
    const uint64_t sum = ((uint64_t)high << 32) | low;
    const uint64_t next = sum + value;
    high = (uint32_t)((next >> 32) & 0xFFFFFFFFu);
    low += value;
  }
  return ~(high + low);
}

static NSError* InsigniaError(NSString* text) {
  return [NSError errorWithDomain:@"XenraInsignia"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : text}];
}

// The file the core generates when the user never picked one. The core makes it
// on the first boot, in its own folder under Documents; walking the app's own
// tree finds it without having to duplicate the core's path choice.
static NSURL* GeneratedEepromURL(void) {
  NSURL* direct = [NSURL
      fileURLWithPath:[Documents() stringByAppendingPathComponent:@"xemu/eeprom.bin"]];
  NSNumber* size = nil;
  [direct getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
  if (size.unsignedLongLongValue == kEepromSize) return direct;

  NSMutableArray<NSString*>* roots = [NSMutableArray array];
  const NSSearchPathDirectory directories[] = {
      NSDocumentDirectory, NSApplicationSupportDirectory, NSLibraryDirectory};
  for (NSSearchPathDirectory directory : directories) {
    NSString* root = NSSearchPathForDirectoriesInDomains(directory,
                                                         NSUserDomainMask, YES)
                         .firstObject;
    if (root && ![roots containsObject:root]) [roots addObject:root];
  }
  for (NSString* root in roots) {
    NSDirectoryEnumerator<NSURL*>* walk = [NSFileManager.defaultManager
              enumeratorAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
        includingPropertiesForKeys:@[ NSURLFileSizeKey ]
                       options:NSDirectoryEnumerationSkipsHiddenFiles
                  errorHandler:nil];
    for (NSURL* file in walk) {
      if (walk.level > 4) {
        [walk skipDescendants];
        continue;
      }
      if (![file.lastPathComponent.lowercaseString isEqualToString:@"eeprom.bin"]) {
        continue;
      }
      NSNumber* length = nil;
      [file getResourceValue:&length forKey:NSURLFileSizeKey error:nil];
      if (length.unsignedLongLongValue == kEepromSize) return file;
    }
  }
  return nil;
}

NSURL* XenraInsigniaEepromURL(void) {
  NSURL* picked = [XenraSettings urlForBookmark:@"eeprom"];
  if (picked) return picked;
  return GeneratedEepromURL();
}

static NSString* DNSAtURL(NSURL* url) {
  if (!url) return nil;
  const BOOL scoped = [url startAccessingSecurityScopedResource];
  NSData* data = [NSData dataWithContentsOfURL:url options:0 error:nil];
  if (scoped) [url stopAccessingSecurityScopedResource];
  if (data.length != kEepromSize) return nil;
  const uint8_t* bytes = data.bytes;
  return [NSString
      stringWithFormat:@"%u.%u.%u.%u", bytes[kXboxLiveDNSOffset],
                       bytes[kXboxLiveDNSOffset + 1],
                       bytes[kXboxLiveDNSOffset + 2],
                       bytes[kXboxLiveDNSOffset + 3]];
}

BOOL XenraInsigniaDNSApplied(void) {
  return [DNSAtURL(XenraInsigniaEepromURL()) isEqualToString:XenraInsigniaPrimaryDNS];
}

BOOL XenraInsigniaApplyDNS(NSError** error) {
  NSURL* url = XenraInsigniaEepromURL();
  if (!url) {
    if (error) {
      *error = InsigniaError(XS(@"No EEPROM yet. Launch any game once to create "
                                "it, then come back."));
    }
    return NO;
  }
  const BOOL scoped = [url startAccessingSecurityScopedResource];
  NSError* local = nil;
  NSData* data = [NSData dataWithContentsOfURL:url options:0 error:&local];
  if (data.length != kEepromSize) {
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (error) {
      *error = InsigniaError(
          local ? [NSString stringWithFormat:XS(@"Could not open the EEPROM: %@"),
                                             local.localizedDescription]
                : XS(@"The EEPROM file is not 256 bytes, so it cannot be edited."));
    }
    return NO;
  }

  uint8_t dns[4] = {46, 101, 64, 175};
  NSMutableData* edited = [data mutableCopy];
  uint8_t* bytes = edited.mutableBytes;
  if (memcmp(bytes + kXboxLiveDNSOffset, dns, sizeof(dns)) == 0) {
    if (scoped) [url stopAccessingSecurityScopedResource];
    return NO;
  }
  memcpy(bytes + kXboxLiveDNSOffset, dns, sizeof(dns));
  WriteLE32(bytes + kUserChecksumOffset,
            XboxChecksum(bytes, kUserChecksumStart, kUserChecksumLength));

  // In place, not atomic: replacing the file would break a bookmarked URL.
  const BOOL saved = [edited writeToURL:url options:0 error:&local];
  if (scoped) [url stopAccessingSecurityScopedResource];
  if (!saved) {
    if (error) {
      *error = InsigniaError(
          [NSString stringWithFormat:XS(@"Could not save the EEPROM: %@"),
                                     local.localizedDescription ?: XS(@"unknown error")]);
    }
    return NO;
  }
  return YES;
}

// --- Wizard state -----------------------------------------------------------

BOOL XenraInsigniaNetworkingOn(void) {
  return [[XenraSettings stringForKey:@"og.net.enable" fallback:@"false"]
      isEqualToString:@"true"];
}

void XenraInsigniaSetNetworkingOn(BOOL on) {
  [XenraSettings setString:on ? @"true" : @"false" forKey:@"og.net.enable"];
}

NSString* XenraInsigniaSetupDiscPath(void) {
  NSString* path = [NSUserDefaults.standardUserDefaults stringForKey:kSetupDiscKey];
  return path.length ? path : nil;
}

void XenraInsigniaRememberSetupDisc(NSString* path) {
  [NSUserDefaults.standardUserDefaults setObject:path forKey:kSetupDiscKey];
}

void XenraInsigniaClearSetupDisc(void) {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kSetupDiscKey];
}

BOOL XenraInsigniaSignedUp(void) {
  return [NSUserDefaults.standardUserDefaults boolForKey:kSignedUpKey];
}

void XenraInsigniaSetSignedUp(BOOL signedUp) {
  [NSUserDefaults.standardUserDefaults setBool:signedUp forKey:kSignedUpKey];
}

BOOL XenraInsigniaAllDone(void) {
  return XenraInsigniaNetworkingOn() && XenraInsigniaDNSApplied() &&
         XenraInsigniaSetupDiscPath() != nil && XenraInsigniaSignedUp();
}

void XenraInsigniaClearProgress(void) {
  // Android's clear: only this screen's own steps. The DNS in the EEPROM and the
  // networking switch are real console state and are deliberately left alone.
  XenraInsigniaClearSetupDisc();
  XenraInsigniaSetSignedUp(NO);
}

// --- Boots ------------------------------------------------------------------

NSString* XenraInsigniaGamesFolder(void) {
  return [Documents() stringByAppendingPathComponent:@"Games OG"];
}

NSString* XenraInsigniaInstalledDiscPath(NSString* sourcePath) {
  return [XenraInsigniaGamesFolder()
      stringByAppendingPathComponent:sourcePath.lastPathComponent];
}

NSString* XenraInsigniaDashboardPath(void) {
  return [Documents() stringByAppendingPathComponent:kDashboardFolder];
}

NSString* XenraInsigniaBootProblem(void) {
  NSString* missing = XenraXemuMissingFiles();
  if (!missing) return nil;
  return [NSString stringWithFormat:
                       XS(@"Still needed: %@. Choose them in the Setup Wizard, "
                          "from Settings."),
                       missing];
}

XenraGameController* XenraInsigniaMakeSetupDiscController(NSString* path) {
  if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
  return [[XenraGameController alloc]
      initWithPath:path
              name:path.lastPathComponent.stringByDeletingPathExtension];
}

XenraGameController* XenraInsigniaMakeDashboardController(void) {
  NSFileManager* files = NSFileManager.defaultManager;
  NSString* marker = XenraInsigniaDashboardPath();
  // A directory, not a file: the boot's file check returns early for one, and
  // the config writer recognises this exact path as "no disc".
  [files createDirectoryAtPath:marker
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  return [[XenraGameController alloc] initWithPath:marker name:@"dashboard"];
}
