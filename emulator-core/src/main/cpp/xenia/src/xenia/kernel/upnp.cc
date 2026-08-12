/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/kernel/upnp.h"

#include <cstdio>
#include <cstring>

#include "xenia/base/logging.h"

#include "miniupnpc.h"
#include "upnpcommands.h"
#include "upnperrors.h"

namespace xe {
namespace kernel {

namespace {

constexpr const char* kProtoUdp = "UDP";
constexpr const char* kProtoTcp = "TCP";

// Indefinite. Routers disagree wildly about non-zero leases - some clamp them,
// some reject the whole call with 402 - and we delete our own mappings in
// Shutdown() anyway, which is the more reliable contract.
constexpr const char* kLeaseDuration = "0";

inline const char* proto_of(bool udp) { return udp ? kProtoUdp : kProtoTcp; }

std::string port_to_string(uint16_t port) {
  char buffer[8];
  std::snprintf(buffer, sizeof(buffer), "%u", static_cast<unsigned>(port));
  return std::string(buffer);
}

}  // namespace

UPnP::~UPnP() { Shutdown(); }

UPnPStatus UPnP::status() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return status_;
}

std::string UPnP::lan_address() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return lan_address_;
}

std::string UPnP::external_address() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return external_address_;
}

bool UPnP::Discover(int timeout_ms) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (discovered_) {
    return status_ == UPnPStatus::kReady;
  }

  int error = 0;
  // ttl 2: the gateway is one hop away. ipv6 off - the mapping we want is for
  // the IPv4 NAT, which is the only thing in the way.
  UPNPDev* devices = upnpDiscover(timeout_ms, nullptr, nullptr, 0, 0, 2, &error);
  if (!devices) {
    XELOGI("UPnP: no devices responded to SSDP (error {})", error);
    status_ = UPnPStatus::kUnavailable;
    discovered_ = true;
    return false;
  }

  auto* urls = new UPNPUrls{};
  auto* data = new IGDdatas{};
  char lan_address[64] = {};
  char wan_address[64] = {};

  const int igd = UPNP_GetValidIGD(devices, urls, data, lan_address,
                                   sizeof(lan_address), wan_address,
                                   sizeof(wan_address));
  freeUPNPDevlist(devices);

  // 3 (DISCONNECTED) is accepted on purpose, and it is not a theoretical case.
  //
  // miniupnpc decides "connected" by calling WANIPConnection:GetStatusInfo.
  // Routers are allowed to advertise that action and then not implement it: a
  // TP-Link running MiniUPnPd 1.8 answers it with UPnP error 401 "Invalid
  // Action" while GetExternalIPAddress and AddPortMapping both work perfectly.
  // Measured on hardware - stock `upnpc` refuses to touch that router, yet a
  // mapping added by hand forwards traffic exactly as asked.
  //
  // Refusing to map here would mean refusing to host on a router that can
  // host. If the gateway really is down, AddPortMapping fails and we find out
  // then, at the cost of one round trip.
  const bool usable = (igd == UPNP_CONNECTED_IGD || igd == UPNP_DISCONNECTED_IGD);

  if (igd == UPNP_PRIVATEIP_IGD) {
    // The gateway works; its own WAN address is reserved. Carrier-grade NAT,
    // or a modem in front of the router. Mappings would succeed and no peer
    // could ever reach us, so call it what it is rather than let the user
    // discover it in a lobby.
    XELOGW("UPnP: gateway has a non-routable external address ({}) - hosting "
           "is not possible from this network", wan_address);
    status_ = UPnPStatus::kNotRoutable;
  } else if (!usable) {
    XELOGI("UPnP: no usable gateway (UPNP_GetValidIGD returned {})", igd);
    status_ = UPnPStatus::kUnavailable;
  } else {
    lan_address_ = lan_address;
    external_address_ = wan_address;

    // wanaddr is only filled when miniupnpc could confirm the connection, so
    // on the disconnected-but-working path above it comes back empty. Ask for
    // it directly, which is the call those routers do implement.
    if (external_address_.empty()) {
      char external[64] = {};
      if (UPNP_GetExternalIPAddress(urls->controlURL, data->first.servicetype,
                                    external) == UPNPCOMMAND_SUCCESS) {
        external_address_ = external;
      }
    }

    XELOGI("UPnP: gateway ready (state {}), lan {} external {}", igd,
           lan_address_, external_address_.empty() ? "unknown"
                                                   : external_address_);
    status_ = UPnPStatus::kReady;
  }

  if (status_ == UPnPStatus::kReady) {
    urls_ = urls;
    igd_data_ = data;
  } else {
    if (igd != UPNP_NO_IGD) {
      FreeUPNPUrls(urls);
    }
    delete urls;
    delete data;
  }

  discovered_ = true;
  return status_ == UPnPStatus::kReady;
}

bool UPnP::AddPortMapping(uint16_t port, bool udp,
                          const std::string& description) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (status_ != UPnPStatus::kReady || !urls_) {
    return false;
  }

  for (const auto& mapping : mappings_) {
    if (mapping.port == port && mapping.udp == udp) {
      return true;  // already ours
    }
  }

  auto* urls = static_cast<UPNPUrls*>(urls_);
  auto* data = static_cast<IGDdatas*>(igd_data_);
  const std::string port_string = port_to_string(port);

  // External and internal port are the same deliberately. The guest tells its
  // peers which port it listens on; a rewritten external port would make that
  // number a lie.
  const int result = UPNP_AddPortMapping(
      urls->controlURL, data->first.servicetype, port_string.c_str(),
      port_string.c_str(), lan_address_.c_str(), description.c_str(),
      proto_of(udp), nullptr, kLeaseDuration);

  if (result != UPNPCOMMAND_SUCCESS) {
    XELOGE("UPnP: could not map {}/{} - {} ({})", port, proto_of(udp),
           strupnperror(result), result);
    return false;
  }

  mappings_.push_back({port, udp});
  XELOGI("UPnP: mapped {}/{} to {}", port, proto_of(udp), lan_address_);
  return true;
}

bool UPnP::DeletePortMapping(uint16_t port, bool udp) {
  std::lock_guard<std::mutex> lock(mutex_);
  return DeletePortMappingLocked(port, udp);
}

bool UPnP::DeletePortMappingLocked(uint16_t port, bool udp) {
  if (!urls_) {
    return false;
  }

  auto* urls = static_cast<UPNPUrls*>(urls_);
  auto* data = static_cast<IGDdatas*>(igd_data_);
  const std::string port_string = port_to_string(port);

  const int result =
      UPNP_DeletePortMapping(urls->controlURL, data->first.servicetype,
                             port_string.c_str(), proto_of(udp), nullptr);

  // Drop it from our list either way. If the delete failed the rule is the
  // router's problem now, and retrying it on every shutdown would just stall
  // teardown forever.
  for (auto it = mappings_.begin(); it != mappings_.end(); ++it) {
    if (it->port == port && it->udp == udp) {
      mappings_.erase(it);
      break;
    }
  }

  if (result != UPNPCOMMAND_SUCCESS) {
    XELOGW("UPnP: could not unmap {}/{} - {} ({})", port, proto_of(udp),
           strupnperror(result), result);
    return false;
  }
  return true;
}

void UPnP::Shutdown() {
  std::lock_guard<std::mutex> lock(mutex_);
  ShutdownLocked();
}

void UPnP::ShutdownLocked() {
  // Leaving a mapping behind is a hole punched in someone's router that
  // outlives the process, so this runs even on the error paths.
  while (!mappings_.empty()) {
    const Mapping mapping = mappings_.back();
    DeletePortMappingLocked(mapping.port, mapping.udp);
    // DeletePortMappingLocked erases it; guard against a mapping that somehow
    // survives so this cannot spin.
    if (!mappings_.empty() && mappings_.back().port == mapping.port &&
        mappings_.back().udp == mapping.udp) {
      mappings_.pop_back();
    }
  }

  if (urls_) {
    FreeUPNPUrls(static_cast<UPNPUrls*>(urls_));
    delete static_cast<UPNPUrls*>(urls_);
    urls_ = nullptr;
  }
  if (igd_data_) {
    delete static_cast<IGDdatas*>(igd_data_);
    igd_data_ = nullptr;
  }

  lan_address_.clear();
  external_address_.clear();
  discovered_ = false;
  status_ = UPnPStatus::kUninitialized;
}

}  // namespace kernel
}  // namespace xe
