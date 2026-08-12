/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_KERNEL_UTIL_NETWORK_ADAPTER_MANAGER_H_
#define XENIA_KERNEL_UTIL_NETWORK_ADAPTER_MANAGER_H_

#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include "xenia/kernel/util/net_utils.h"

namespace xe {
namespace kernel {

/*!
 * Which network interface 360 netplay presents to the guest.
 *
 * *** THIS IS A REWRITE, NOT A PORT. *** Upstream netplay's version types its
 * entire public interface on IP_ADAPTER_ADDRESSES and calls GetAdaptersAddresses
 * from iphlpapi - Windows only, with no POSIX equivalent to swap in. Replacing
 * the body would not have been enough; the header itself is unusable here.
 *
 * So this exposes only the platform-NEUTRAL subset, which turns out to be all
 * XLiveAPI actually consumes of it: the selected interface's local IPv4 address
 * and whether that address is routable. The GUID/friendly-name/IfIndex surface
 * is Windows plumbing for a Windows adapter picker and has no meaning on
 * Android, where the user does not choose a NIC.
 *
 * Backed by getifaddrs(), which Android's libc has.
 */
class AdapterInfo {
 public:
  //! Interface name as the kernel reports it: wlan0, rmnet_data0, lo.
  std::string name;
  //! IPv4 address bound to it.
  sockaddr_in address = {};
  //! Hardware address, zeroed when the kernel will not tell us (see the .cc).
  uint64_t mac = 0;
  bool is_loopback = false;
  bool is_up = false;
  /*!
   * True when the address is globally routable, i.e. NOT RFC1918 / CGNAT.
   *
   * On a phone this is almost always FALSE even on a working connection - the
   * handset sits behind the router's NAT. It is not a health check; it
   * distinguishes "we are behind a NAT we can port-map" from "we already hold
   * a public address", which changes whether hosting needs UPnP at all.
   */
  bool is_wan_routing = false;
};

class NetworkAdapterManager {
 public:
  NetworkAdapterManager() = default;

  NetworkAdapterManager(const NetworkAdapterManager&) = delete;
  NetworkAdapterManager& operator=(const NetworkAdapterManager&) = delete;

  /*!
   * Enumerate interfaces and pick one. Cheap enough to re-run whenever the
   * network changes, and it must be re-run then - a phone moving between Wi-Fi
   * and mobile data changes both the address and whether hosting can work.
   */
  void Initialize();

  //! Re-run selection over the interfaces found by the last Initialize().
  void SelectBestInterface();

  bool IsInterfaceSelected() const;

  //! Zeroed when nothing is selected, so callers can send it to the guest as-is.
  sockaddr_in GetSelectedAdapterLocalIP() const;
  std::string GetSelectedAdapterLocalIPString() const;
  std::string GetSelectedAdapterName() const;
  MacAddress GetSelectedAdapterMacAddress() const;

  //! See AdapterInfo::is_wan_routing - this is about NAT, not connectivity.
  bool IsSelectedAdapterWANRouting() const;

  std::vector<std::string> GetAdaptersNames() const;
  const std::vector<AdapterInfo>& GetAdapters() const { return adapters_; }

 private:
  //! Ranks a candidate; higher wins. Ties break on enumeration order.
  static int ScoreAdapter(const AdapterInfo& adapter);

  mutable std::mutex mutex_;
  std::vector<AdapterInfo> adapters_;
  std::optional<AdapterInfo> selected_;
};

}  // namespace kernel
}  // namespace xe

#endif  // XENIA_KERNEL_UTIL_NETWORK_ADAPTER_MANAGER_H_
