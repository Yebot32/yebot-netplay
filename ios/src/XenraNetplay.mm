#import "XenraNetplay.h"

#ifdef XENRA_UITEST

// The simulator tour stubs the cores, so there is nothing to create a profile
// with or to enumerate. The dashboard renders its normal sheet with these
// empty results.

NSString* XenraNetplayProfileSummary(NSString* content_root) { return nil; }
NSString* XenraNetplayProfileXuid(NSString* content_root) { return nil; }
NSString* XenraNetplayEnsureProfile(NSString* content_root, NSString* gamertag) {
  return nil;
}
NSString* XenraNetplayCreateProfile(NSString* content_root, NSString* gamertag) {
  return nil;
}
BOOL XenraNetplayRenameProfile(NSString* content_root, NSString* xuid,
                               NSString* gamertag) {
  return NO;
}
NSString* XenraNetplayAdapterSummary(void) { return nil; }
int XenraNetplayUPnPDiscover(int timeout_ms) { return 0; }
NSString* XenraNetplayUPnPStatus(void) { return nil; }
NSString* XenraNetplayUPnPLanAddress(void) { return nil; }
NSString* XenraNetplayUPnPExternalAddress(void) { return nil; }
BOOL XenraNetplayUPnPTestMapping(int port) { return NO; }

#else

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <string>

#include "ios_emu.h"
#include "xenia/kernel/upnp.h"
#include "xenia/kernel/util/network_adapter_manager.h"
#include "xenia/kernel/xam/profile_standalone.h"

namespace {

std::filesystem::path PathFrom(NSString* path) {
  return std::filesystem::u8path(path.UTF8String ?: "");
}

NSString* NsString(const std::string& value) {
  return value.empty() ? nil : [NSString stringWithUTF8String:value.c_str()];
}

std::string XuidText(uint64_t xuid) {
  char buffer[17] = {};
  std::snprintf(buffer, sizeof(buffer), "%016llX",
                static_cast<unsigned long long>(xuid));
  return buffer;
}

xe::kernel::UPnP& Upnp() {
  static xe::kernel::UPnP instance;
  return instance;
}

xe::kernel::NetworkAdapterManager& Adapters() {
  static xe::kernel::NetworkAdapterManager instance;
  return instance;
}

// The core reads this cvar when the kernel starts; xe_ios_set_cvar takes TOML,
// so a string value has to arrive quoted.
void SignIn(const std::string& xuid) {
  if (xuid.empty()) {
    return;
  }
  const std::string quoted = "\"" + xuid + "\"";
  xe_ios_set_cvar("logged_profile_slot_0_xuid", quoted.c_str());
}

constexpr uint32_t kProfileLanguage = 1;
constexpr uint32_t kProfileCountry = 103;

}  // namespace

NSString* XenraNetplayProfileSummary(NSString* content_root) {
  const auto profiles =
      xe::kernel::xam::ListStandaloneProfiles(PathFrom(content_root));
  return profiles.empty() ? nil : NsString(profiles.front().gamertag);
}

NSString* XenraNetplayProfileXuid(NSString* content_root) {
  const auto profiles =
      xe::kernel::xam::ListStandaloneProfiles(PathFrom(content_root));
  return profiles.empty() ? nil : NsString(XuidText(profiles.front().xuid));
}

NSString* XenraNetplayEnsureProfile(NSString* content_root,
                                    NSString* gamertag) {
  const auto root = PathFrom(content_root);
  const auto profiles = xe::kernel::xam::ListStandaloneProfiles(root);
  std::string xuid;
  if (!profiles.empty()) {
    xuid = XuidText(profiles.front().xuid);
  } else {
    xuid = xe::kernel::xam::CreateStandaloneProfile(
        root, gamertag.UTF8String ?: "Xenra", kProfileLanguage,
        kProfileCountry);
  }
  SignIn(xuid);
  return NsString(xuid);
}

NSString* XenraNetplayCreateProfile(NSString* content_root,
                                    NSString* gamertag) {
  const std::string xuid = xe::kernel::xam::CreateStandaloneProfile(
      PathFrom(content_root), gamertag.UTF8String ?: "", kProfileLanguage,
      kProfileCountry);
  SignIn(xuid);
  return NsString(xuid);
}

BOOL XenraNetplayRenameProfile(NSString* content_root, NSString* xuid,
                               NSString* gamertag) {
  if (!xuid.length || !gamertag.length) {
    return NO;
  }
  const uint64_t value = std::strtoull(xuid.UTF8String, nullptr, 16);
  return xe::kernel::xam::RenameStandaloneProfile(
             PathFrom(content_root), value, gamertag.UTF8String,
             kProfileLanguage, kProfileCountry) == 0;
}

NSString* XenraNetplayAdapterSummary(void) {
  auto& manager = Adapters();
  manager.Initialize();
  std::string summary = manager.GetSelectedAdapterName();
  if (!summary.empty()) {
    summary += " (" + manager.GetSelectedAdapterLocalIPString() + ", " +
               (manager.IsSelectedAdapterWANRouting() ? "WAN" : "NAT") + ")";
  }
  return NsString(summary);
}

int XenraNetplayUPnPDiscover(int timeout_ms) {
  return static_cast<int>(Upnp().Discover(timeout_ms));
}

NSString* XenraNetplayUPnPStatus(void) {
  switch (Upnp().status()) {
    case xe::kernel::UPnPStatus::kReady:
      return @"ready";
    case xe::kernel::UPnPStatus::kNotRoutable:
      return @"not routable";
    case xe::kernel::UPnPStatus::kUnavailable:
      return @"unavailable";
    case xe::kernel::UPnPStatus::kUninitialized:
      return @"uninitialized";
  }
  return @"unknown";
}

NSString* XenraNetplayUPnPLanAddress(void) {
  return NsString(Upnp().lan_address());
}

NSString* XenraNetplayUPnPExternalAddress(void) {
  return NsString(Upnp().external_address());
}

BOOL XenraNetplayUPnPTestMapping(int port) {
  if (port <= 0 || port > 65535) {
    return NO;
  }
  const auto value = static_cast<uint16_t>(port);
  if (!Upnp().AddPortMapping(value, true, "Xenra System Link")) {
    return NO;
  }
  Upnp().DeletePortMapping(value, true);
  return YES;
}

#endif  // XENRA_UITEST
