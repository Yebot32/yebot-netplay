/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_NET_SYSTEM_LINK_H_
#define XENIA_NET_SYSTEM_LINK_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <span>
#include <vector>

#include "xenia/net/packet_transport.h"
#include "xenia/net/xnet_association.h"

namespace xe::net {

// Winsock error codes, as the guest sees them.
inline constexpr uint32_t kWsaInterrupted = 10004;
inline constexpr uint32_t kWsaInvalid = 10022;
inline constexpr uint32_t kWsaWouldBlock = 10035;
inline constexpr uint32_t kWsaAlready = 10037;
inline constexpr uint32_t kWsaMessageSize = 10040;
inline constexpr uint32_t kWsaAddressInUse = 10048;
inline constexpr uint32_t kWsaNetworkDown = 10050;
inline constexpr uint32_t kWsaNoBuffers = 10055;
inline constexpr uint32_t kWsaTimedOut = 10060;
inline constexpr uint32_t kWsaHostUnreachable = 10065;

// Host byte order.
struct Endpoint {
  uint32_t address = 0;
  uint16_t port = 0;
  bool operator==(const Endpoint&) const = default;
};

struct Peer {
  // The peer's XNADDR as the guest passed it.
  secure::Address address{};
  KeyId key_id{};
  uint32_t secure_address = 0;
};

// A guest UDP or VDP socket bound to a System Link port. Errors are Winsock
// codes.
class SystemLinkPort {
 public:
  static constexpr uint32_t kWaitForever = UINT32_MAX;

  virtual ~SystemLinkPort() = default;
  virtual uint16_t port() const = 0;
  virtual void Close() = 0;
  // Size of the next datagram, 0 if none is queued.
  virtual size_t PendingBytes() const = 0;
  // A receive would return without waiting.
  virtual bool Readable() const = 0;
  // Runs on any thread when a datagram arrives at an empty queue or the LAN
  // goes down, and right away if already Readable(). It must not call back
  // into the System Link.
  virtual void SetReadyCallback(std::function<void()> callback) = 0;
  virtual int Send(Endpoint destination, std::span<const uint8_t> data,
                   uint32_t& error) = 0;
  // Waits up to |wait_ms| for a datagram, 0 returns right away.
  virtual int Receive(std::span<uint8_t> buffer, bool peek, Endpoint& source,
                      uint32_t wait_ms, uint32_t& error) = 0;
};

// One console on the System Link LAN: its keys, the peers it mapped to secure
// addresses and the secure associations with them, run over a packet
// transport. Methods are thread safe. Secure addresses are opaque handles in
// 0.0.0.0/8 that the guest passes to socket calls in place of a peer's IP.
class SystemLink {
 public:
  // Fills in |association|'s identity and credential.
  SystemLink(uint32_t address,
             std::shared_ptr<secure::PacketTransport> transport,
             secure::AssociationConfig association);
  ~SystemLink();

  // This console's XNADDR.
  const secure::Address& identity() const { return identity_; }
  static uint64_t MachineId(const secure::Address& address);

  static void CreateKey(KeyId& id, Key& key);
  uint32_t RegisterKey(const KeyId& id, const Key& key);
  uint32_t UnregisterKey(const KeyId& id);
  bool GetKey(const KeyId& id, Key& key) const;

  uint32_t Map(const secure::Address& address, const KeyId& id,
               uint32_t& secure);
  uint32_t Reverse(uint32_t secure, secure::Address& address, KeyId& id) const;
  uint32_t Unmap(uint32_t secure);
  uint32_t Connect(uint32_t secure);
  uint32_t ConnectStatus(uint32_t secure) const;
  std::vector<Peer> peers() const;

  // Port 0 picks a free one.
  std::unique_ptr<SystemLinkPort> Bind(uint16_t port, bool vdp,
                                       uint32_t& error);
  // Drops every key, peer and association and closes every bound port.
  void Reset();

 private:
  struct State;
  class Port;

  secure::Address identity_{};
  // Shared with the bound ports, which can outlive this.
  std::shared_ptr<State> state_;
};

}  // namespace xe::net

#endif  // XENIA_NET_SYSTEM_LINK_H_
