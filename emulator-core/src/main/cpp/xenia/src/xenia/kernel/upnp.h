/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_KERNEL_UPNP_H_
#define XENIA_KERNEL_UPNP_H_

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace xe {
namespace kernel {

/*!
 * How usable the router is for hosting.
 *
 * The distinction between kNotRoutable and kUnavailable is the one worth
 * keeping: both mean "you cannot host", but only the first means the router
 * answered perfectly well and the problem is upstream of it (carrier-grade
 * NAT). Telling a user to enable UPnP when they are behind CGNAT sends them
 * to fix a setting that was never wrong.
 */
enum class UPnPStatus {
  kUninitialized,
  //! No IGD answered, or what answered was not an IGD.
  kUnavailable,
  //! An IGD is present but its external address is reserved (RFC1918 /
  //! CGNAT). Mappings will appear to succeed and nobody will reach us.
  kNotRoutable,
  //! Usable.
  kReady,
};

/*!
 * UPnP IGD port mapping, for hosting a netplay session.
 *
 * Deliberately narrow: discover a gateway, map a port, unmap it. Everything a
 * host needs and nothing else.
 *
 * NOT thread safe by accident - every public method takes the lock, because
 * Discover() blocks for the SSDP timeout and the guest must never be the
 * thread that waits for it. Call Discover() off the guest's dispatch threads.
 */
class UPnP {
 public:
  UPnP() = default;
  ~UPnP();

  UPnP(const UPnP&) = delete;
  UPnP& operator=(const UPnP&) = delete;

  /*!
   * Find a gateway. Blocks for up to `timeout_ms` while SSDP replies arrive.
   *
   * Idempotent: a second call while already discovered is a no-op, so this is
   * safe to call defensively before mapping a port.
   *
   * \return true if a gateway was found that we can map ports on. Note that
   *         kNotRoutable returns FALSE - a mapping there would silently do
   *         nothing useful.
   */
  bool Discover(int timeout_ms = 2000);

  //! Drop every mapping we made, then release the gateway.
  void Shutdown();

  UPnPStatus status() const;
  bool is_ready() const { return status() == UPnPStatus::kReady; }

  //! Our address on the LAN, as the gateway sees us. Empty until discovered.
  std::string lan_address() const;
  //! The gateway's public address. Empty until discovered.
  std::string external_address() const;

  /*!
   * Map an external port to the same port on this host.
   *
   * Re-mapping a port we already hold is a no-op rather than an error, since
   * a title that restarts a session should not have to care.
   */
  bool AddPortMapping(uint16_t port, bool udp, const std::string& description);
  bool DeletePortMapping(uint16_t port, bool udp);

 private:
  struct Mapping {
    uint16_t port;
    bool udp;
  };

  // Callers already hold the lock.
  bool DeletePortMappingLocked(uint16_t port, bool udp);
  void ShutdownLocked();

  mutable std::mutex mutex_;
  bool discovered_ = false;
  UPnPStatus status_ = UPnPStatus::kUninitialized;
  std::string lan_address_;
  std::string external_address_;
  //! Only what WE mapped, so Shutdown() cannot delete a rule the user or
  //! another application put there.
  std::vector<Mapping> mappings_;

  // Opaque so miniupnpc's headers stay out of this one - they drag in
  // platform socket headers that clash with xenia's own.
  void* urls_ = nullptr;
  void* igd_data_ = nullptr;
};

}  // namespace kernel
}  // namespace xe

#endif  // XENIA_KERNEL_UPNP_H_
