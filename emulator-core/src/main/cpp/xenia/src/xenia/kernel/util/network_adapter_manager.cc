/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/kernel/util/network_adapter_manager.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/types.h>

#include <cstring>

#include "xenia/base/logging.h"

namespace xe {
namespace kernel {

namespace {

//! RFC1918, CGNAT (100.64/10), link-local and loopback - everything that cannot
//! be reached from the internet without something in front of it.
bool IsPrivateIPv4(uint32_t host_order) {
  const uint8_t a = static_cast<uint8_t>((host_order >> 24) & 0xFF);
  const uint8_t b = static_cast<uint8_t>((host_order >> 16) & 0xFF);

  if (a == 10) return true;                            // 10/8
  if (a == 127) return true;                           // loopback
  if (a == 172 && b >= 16 && b <= 31) return true;     // 172.16/12
  if (a == 192 && b == 168) return true;               // 192.168/16
  if (a == 169 && b == 254) return true;               // link-local
  if (a == 100 && b >= 64 && b <= 127) return true;    // CGNAT, 100.64/10
  return false;
}

/*!
 * Hardware address for an interface.
 *
 * Returns 0 on Android in the ordinary case, and that is EXPECTED, not a bug:
 * since Android 6 the MAC is privileged data, /sys/class/net/<if>/address is
 * unreadable to apps and getifaddrs reports no AF_PACKET entry. Callers must
 * treat 0 as "unknown" - netplay derives its console ID from elsewhere rather
 * than from a real NIC address.
 */
uint64_t ReadMacAddress(const std::string& interface_name) {
  // Deliberately not attempting /sys or NETLINK. Both are blocked for apps on
  // every Android this runs on, and probing them just produces noise in logs.
  (void)interface_name;
  return 0;
}

}  // namespace

void NetworkAdapterManager::Initialize() {
  std::vector<AdapterInfo> found;

  ifaddrs* head = nullptr;
  if (getifaddrs(&head) != 0 || !head) {
    XELOGE("NetworkAdapterManager: getifaddrs failed");
    std::lock_guard<std::mutex> lock(mutex_);
    adapters_.clear();
    selected_.reset();
    return;
  }

  for (ifaddrs* it = head; it != nullptr; it = it->ifa_next) {
    if (!it->ifa_addr || it->ifa_addr->sa_family != AF_INET) {
      continue;
    }

    AdapterInfo adapter;
    adapter.name = it->ifa_name ? it->ifa_name : "";
    std::memcpy(&adapter.address, it->ifa_addr, sizeof(sockaddr_in));
    adapter.is_up = (it->ifa_flags & IFF_UP) != 0 &&
                    (it->ifa_flags & IFF_RUNNING) != 0;
    adapter.is_loopback = (it->ifa_flags & IFF_LOOPBACK) != 0;

    const uint32_t host_order = ntohl(adapter.address.sin_addr.s_addr);
    adapter.is_wan_routing = !IsPrivateIPv4(host_order);
    adapter.mac = ReadMacAddress(adapter.name);

    found.push_back(std::move(adapter));
  }

  freeifaddrs(head);

  {
    std::lock_guard<std::mutex> lock(mutex_);
    adapters_ = std::move(found);
  }

  SelectBestInterface();
}

int NetworkAdapterManager::ScoreAdapter(const AdapterInfo& adapter) {
  // Never usable: no address, down, or loopback.
  if (adapter.is_loopback || !adapter.is_up ||
      adapter.address.sin_addr.s_addr == 0) {
    return -1;
  }

  int score = 10;

  // Wi-Fi first, and by a wide margin. Hosting over mobile data cannot work -
  // carriers put the handset behind a shared address, measured on this device
  // as 10.56.36.243/29 - so picking cellular would hand the guest an address
  // nobody can reach. Preferring it here is what makes "Wi-Fi only" true rather
  // than merely documented.
  if (adapter.name.rfind("wlan", 0) == 0) {
    score += 100;
  } else if (adapter.name.rfind("rmnet", 0) == 0 ||
             adapter.name.rfind("ccmni", 0) == 0) {
    score -= 50;  // cellular
  }

  // A tunnel is usually a VPN. It may work, but it is not what the user's
  // router will be port-mapping, so it loses to Wi-Fi.
  if (adapter.name.rfind("tun", 0) == 0 ||
      adapter.name.rfind("ppp", 0) == 0) {
    score -= 20;
  }

  return score;
}

void NetworkAdapterManager::SelectBestInterface() {
  std::lock_guard<std::mutex> lock(mutex_);

  selected_.reset();
  int best_score = 0;

  for (const auto& adapter : adapters_) {
    const int score = ScoreAdapter(adapter);
    if (score > best_score) {
      best_score = score;
      selected_ = adapter;
    }
  }

  if (selected_.has_value()) {
    XELOGI("NetworkAdapterManager: selected {} ({}), WAN routing: {}",
           selected_->name, ip_to_string(selected_->address),
           selected_->is_wan_routing ? "yes" : "no");
  } else {
    XELOGW("NetworkAdapterManager: no usable interface");
  }
}

bool NetworkAdapterManager::IsInterfaceSelected() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_.has_value();
}

sockaddr_in NetworkAdapterManager::GetSelectedAdapterLocalIP() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_.has_value() ? selected_->address : sockaddr_in{};
}

std::string NetworkAdapterManager::GetSelectedAdapterLocalIPString() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_.has_value() ? ip_to_string(selected_->address) : std::string();
}

std::string NetworkAdapterManager::GetSelectedAdapterName() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_.has_value() ? selected_->name : std::string();
}

MacAddress NetworkAdapterManager::GetSelectedAdapterMacAddress() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return MacAddress(selected_.has_value() ? selected_->mac : 0);
}

bool NetworkAdapterManager::IsSelectedAdapterWANRouting() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return selected_.has_value() && selected_->is_wan_routing;
}

std::vector<std::string> NetworkAdapterManager::GetAdaptersNames() const {
  std::lock_guard<std::mutex> lock(mutex_);
  std::vector<std::string> names;
  names.reserve(adapters_.size());
  for (const auto& adapter : adapters_) {
    names.push_back(adapter.name);
  }
  return names;
}

}  // namespace kernel
}  // namespace xe
