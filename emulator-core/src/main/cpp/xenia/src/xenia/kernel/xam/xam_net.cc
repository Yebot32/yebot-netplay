/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include <atomic>
#include <chrono>
#include <cstring>
#include <map>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "xenia/base/logging.h"
#include "xenia/base/threading.h"
#include "xenia/emulator.h"
#include "xenia/kernel/kernel_state.h"
#include "xenia/kernel/util/net_utils.h"
#include "xenia/kernel/util/network_adapter_manager.h"
#include "xenia/kernel/util/shim_utils.h"
#include "xenia/kernel/xam/xam_module.h"
#include "xenia/kernel/xam/xam_private.h"
#include "xenia/kernel/xboxkrnl/xboxkrnl_error.h"
#include "xenia/kernel/xboxkrnl/xboxkrnl_threading.h"
#include "xenia/kernel/xevent.h"
#include "xenia/kernel/xsocket.h"
#include "xenia/kernel/xthread.h"
#include "xenia/xbox.h"

DEFINE_bool(network_enabled, true,
            "Let titles open host sockets. The XNet address and session layer "
            "is stubbed, so guest traffic cannot reach a peer, but titles that "
            "do not check for socket creation failure crash outright when this "
            "is off. Turn it off only for titles that block indefinitely on a "
            "socket that never answers.",
            "Kernel");

// Values match upstream netplay's NETWORK_MODE so the rest of that port (see
// docs/netplay-port/) reads this cvar unchanged. Only OFFLINE and LAN are
// implemented here - XBOXLIVE needs XLiveAPI, which does not build against
// Edge yet, and is deliberately left to fall through to OFFLINE behaviour.
//
// DEFAULT IS OFFLINE, which is exactly what the stubs did before. System Link
// is opt-in until it has been verified against a second console; flipping this
// default is a decision to make on evidence, not on the code compiling.
DEFINE_int32(network_mode, 0,
             "0 = offline, the console reports no usable network address. "
             "1 = LAN, System Link over the host's own subnet: the guest is "
             "handed the real local IP and peers resolve to their real "
             "addresses. 2 = Xbox Live, NOT IMPLEMENTED, treated as offline.",
             "Kernel");

namespace NETWORK_MODE {
constexpr int32_t OFFLINE = 0;
constexpr int32_t LAN = 1;
constexpr int32_t XBOXLIVE = 2;
}  // namespace NETWORK_MODE

#ifdef XE_PLATFORM_WIN32
// NOTE: must be included last as it expects windows.h to already be included.
#ifndef _WINSOCK_DEPRECATED_NO_WARNINGS
#define _WINSOCK_DEPRECATED_NO_WARNINGS  // inet_addr
#endif
#include <winsock2.h>  // NOLINT(build/include_order)
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

namespace xe {
namespace kernel {
namespace xam {

// https://github.com/G91/TitanOffLine/blob/1e692d9bb9dfac386d08045ccdadf4ae3227bb5e/xkelib/xam/xamNet.h
enum {
  XNCALLER_INVALID = 0x0,
  XNCALLER_TITLE = 0x1,
  XNCALLER_SYSAPP = 0x2,
  XNCALLER_XBDM = 0x3,
  XNCALLER_TEST = 0x4,
  NUM_XNCALLER_TYPES = 0x4,
};

enum PLATFORM_TYPE : uint32_t { Xbox1, Xbox360, PC };

// Security Gateway Address - the layout of XNADDR::abOnline.
//
// Taken from docs/netplay-port/xnet.h.ported, which is upstream netplay's
// xnet.h. It used to be a flat uint8_t[20] here and stayed zeroed; a peer
// applying upstream's own test
//
//     IsDeadSg(sg) := sg.security_parameter_index == 0 && sg.xbox_id == 0
//
// therefore read every console we advertised as a DEAD secure address.
//
// *** MUST be pack(1). *** xbox_id is 8 bytes, so the natural alignment would
// round the struct up to 24 and silently push XNADDR to 40 - the static
// asserts below are the guard, since nothing else in this file would notice.
#pragma pack(push, 1)
struct SGADDR {
  in_addr ina;                                // SG address for the client
  xe::be<uint32_t> security_parameter_index;  // Assigned by the SG
  xe::be<uint64_t> xbox_id;                   // Client machine account id
  uint8_t platform_type;
  uint8_t reserved[3];
};
#pragma pack(pop)
static_assert_size(SGADDR, 0x14);

// https://github.com/pmrowla/hl2sdk-csgo/blob/master/common/xbox/xboxstubs.h
typedef struct {
  // FYI: IN_ADDR should be in network-byte order.
  in_addr ina;                   // IP address (zero if not static/DHCP)
  in_addr inaOnline;             // Online IP address (zero if not online)
  xe::be<uint16_t> wPortOnline;  // Online port
  uint8_t abEnet[6];             // Ethernet MAC address
  SGADDR abOnline;               // Online identification
} XNADDR;
static_assert_size(XNADDR, 0x24);

struct XNDNS {
  xe::be<int32_t> status;
  xe::be<uint32_t> cina;
  in_addr aina[8];
};
static_assert_size(XNDNS, 0x28);

struct XNQOSINFO {
  uint8_t flags;
  uint8_t reserved;
  xe::be<uint16_t> probes_xmit;
  xe::be<uint16_t> probes_recv;
  xe::be<uint16_t> data_len;
  xe::be<uint32_t> data_ptr;
  xe::be<uint16_t> rtt_min_in_msecs;
  xe::be<uint16_t> rtt_med_in_msecs;
  xe::be<uint32_t> up_bits_per_sec;
  xe::be<uint32_t> down_bits_per_sec;
};
static_assert_size(XNQOSINFO, 0x18);

struct XNQOS {
  xe::be<uint32_t> count;
  xe::be<uint32_t> count_pending;
  XNQOSINFO info[1];
};

struct Xsockaddr_t {
  xe::be<uint16_t> sa_family;
  char sa_data[14];
};
static_assert_size(XNQOS, 0x20);

struct X_WSADATA {
  xe::be<uint16_t> version;
  xe::be<uint16_t> version_high;
  char description[256 + 1];
  char system_status[128 + 1];
  xe::be<uint16_t> max_sockets;
  xe::be<uint16_t> max_udpdg;
  xe::be<uint32_t> vendor_info_ptr;
};
static_assert_size(X_WSADATA, 0x190);

struct XWSABUF {
  xe::be<uint32_t> len;
  xe::be<uint32_t> buf_ptr;
};

struct XWSAOVERLAPPED {
  xe::be<uint32_t> internal;
  xe::be<uint32_t> internal_high;
  union {
    struct {
      xe::be<uint32_t> low;
      xe::be<uint32_t> high;
    } offset;  // must be named to avoid GCC error
    xe::be<uint32_t> pointer;
  };
  xe::be<uint32_t> event_handle;
};

// System Link datagrams are tiny - the discovery advertisement is 187 bytes and
// the join exchange is 20 out, 12 back - and the ONLY direct evidence of what a
// title is actually saying to its peer. Nobody had ever looked at the bytes;
// #20 5.3 asked for exactly this. Anything larger than a control packet is
// gameplay traffic and would bury the trace, so it is truncated.
static constexpr size_t kMaxPacketDumpBytes = 256;

static std::string HexDumpPacket(const uint8_t* data, size_t length) {
  static constexpr char kHexDigits[] = "0123456789ABCDEF";
  const size_t shown = std::min(length, kMaxPacketDumpBytes);
  std::string out;
  out.reserve(shown * 3 + 16);
  for (size_t i = 0; i < shown; ++i) {
    if (i) {
      out.push_back(' ');
    }
    out.push_back(kHexDigits[data[i] >> 4]);
    out.push_back(kHexDigits[data[i] & 0x0F]);
  }
  if (shown < length) {
    out += " ...";
  }
  return out;
}

void LoadSockaddr(const uint8_t* ptr, sockaddr* out_addr) {
  out_addr->sa_family = xe::load_and_swap<uint16_t>(ptr + 0);
  switch (out_addr->sa_family) {
    case AF_INET: {
      auto in_addr = reinterpret_cast<sockaddr_in*>(out_addr);
      in_addr->sin_port = xe::load_and_swap<uint16_t>(ptr + 2);
      // Maybe? Depends on type.
      in_addr->sin_addr.s_addr = *(uint32_t*)(ptr + 4);
      break;
    }
    default:
      assert_unhandled_case(out_addr->sa_family);
      break;
  }
}

void StoreSockaddr(const sockaddr& addr, uint8_t* ptr) {
  switch (addr.sa_family) {
    case AF_UNSPEC:
      std::memset(ptr, 0, sizeof(addr));
      break;
    case AF_INET: {
      auto& in_addr = reinterpret_cast<const sockaddr_in&>(addr);
      xe::store_and_swap<uint16_t>(ptr + 0, in_addr.sin_family);
      xe::store_and_swap<uint16_t>(ptr + 2, in_addr.sin_port);
      // Maybe? Depends on type.
      xe::store_and_swap<uint32_t>(ptr + 4, in_addr.sin_addr.s_addr);
      break;
    }
    default:
      assert_unhandled_case(addr.sa_family);
      break;
  }
}

// https://github.com/joolswills/mameox/blob/master/MAMEoX/Sources/xbox_Network.cpp#L136
struct XNetStartupParams {
  uint8_t cfgSizeOfStruct;
  uint8_t cfgFlags;
  uint8_t cfgSockMaxDgramSockets;
  uint8_t cfgSockMaxStreamSockets;
  uint8_t cfgSockDefaultRecvBufsizeInK;
  uint8_t cfgSockDefaultSendBufsizeInK;
  uint8_t cfgKeyRegMax;
  uint8_t cfgSecRegMax;
  uint8_t cfgQosDataLimitDiv4;
  uint8_t cfgQosProbeTimeoutInSeconds;
  uint8_t cfgQosProbeRetries;
  uint8_t cfgQosSrvMaxSimultaneousResponses;
  uint8_t cfgQosPairWaitTimeInSeconds;
};
static_assert_size(XNetStartupParams, 0xD);

XNetStartupParams xnet_startup_params = {0};

dword_result_t NetDll_XNetStartup_entry(dword_t caller,
                                        pointer_t<XNetStartupParams> params) {
  XELOGI("NetDll_XNetStartup: caller={}, params={:08X}", caller.value(),
         params.guest_address());

  if (params) {
    assert_true(params->cfgSizeOfStruct == sizeof(XNetStartupParams));
    std::memcpy(&xnet_startup_params, params, sizeof(XNetStartupParams));
  }

  auto xam = kernel_state()->GetKernelModule<XamModule>("xam.xex");

  /*
  if (!xam->xnet()) {
    auto xnet = new XNet(kernel_state());
    xnet->Initialize();

    xam->set_xnet(xnet);
  }
  */

  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetStartup, kNetworking, kImplemented);

// https://github.com/jogolden/testdev/blob/master/xkelib/syssock.h#L46
dword_result_t NetDll_XNetStartupEx_entry(dword_t caller,
                                          pointer_t<XNetStartupParams> params,
                                          dword_t versionReq) {
  // versionReq
  // MW3, Ghosts: 0x20501400

  return NetDll_XNetStartup_entry(caller, params);
}
DECLARE_XAM_EXPORT1(NetDll_XNetStartupEx, kNetworking, kImplemented);

dword_result_t NetDll_XNetCleanup_entry(dword_t caller, lpvoid_t params) {
  auto xam = kernel_state()->GetKernelModule<XamModule>("xam.xex");
  // auto xnet = xam->xnet();
  // xam->set_xnet(nullptr);

  // TODO: Shut down and delete.
  // delete xnet;

  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetCleanup, kNetworking, kImplemented);

dword_result_t NetDll_XNetGetOpt_entry(dword_t one, dword_t option_id,
                                       lpvoid_t buffer_ptr,
                                       lpdword_t buffer_size) {
  assert_true(one == 1);
  switch (option_id) {
    case 1:
      if (*buffer_size < sizeof(XNetStartupParams)) {
        *buffer_size = sizeof(XNetStartupParams);
        return uint32_t(X_WSAError::X_WSAEMSGSIZE);
      }
      std::memcpy(buffer_ptr, &xnet_startup_params, sizeof(XNetStartupParams));
      return 0;
    default:
      XELOGE("NetDll_XNetGetOpt: option {} unimplemented",
             static_cast<uint32_t>(option_id));
      return uint32_t(X_WSAError::X_WSAEINVAL);
  }
}
DECLARE_XAM_EXPORT1(NetDll_XNetGetOpt, kNetworking, kSketchy);

dword_result_t NetDll_XNetRandom_entry(dword_t caller, lpvoid_t buffer_ptr,
                                       dword_t length) {
  uint8_t* buffer_data_ptr = buffer_ptr.as<uint8_t*>();

  if (buffer_data_ptr == nullptr || length == 0) {
    return X_ERROR_SUCCESS;
  }

  std::random_device rnd;
  std::mt19937_64 gen(rnd());
  std::uniform_int_distribution<int> dist(0,
                                          std::numeric_limits<uint8_t>::max());

  std::generate(buffer_data_ptr, buffer_data_ptr + length,
                [&]() { return static_cast<uint8_t>(dist(gen)); });

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetRandom, kNetworking, kImplemented);

dword_result_t NetDll_WSAStartup_entry(dword_t caller, word_t version,
                                       pointer_t<X_WSADATA> data_ptr) {
  // TODO(benvanik): abstraction layer needed.
  XELOGI("NetDll_WSAStartup: version={:04X}, data_ptr={:08X}", version.value(),
         data_ptr.guest_address());

  int ret = 0;

#ifdef XE_PLATFORM_WIN32
  WSADATA wsaData = {};

  ret = WSAStartup(version, &wsaData);
#endif

  if (data_ptr) {
    auto data_out = kernel_state()->memory()->TranslateVirtual(data_ptr);

#ifdef XE_PLATFORM_WIN32
    data_ptr->version = wsaData.wVersion;
    data_ptr->version_high = wsaData.wHighVersion;
#else
    data_ptr->version = version.value();
    data_ptr->version_high = 0x0202;
#endif

    // Some games (5841099F) want this value round-tripped - they'll compare if
    // it changes and bugcheck if it does.
    // vendor_info_ptr is at offset 0x18A (after max_udpdg at 0x188)
    uint32_t vendor_ptr = xe::load_and_swap<uint32_t>(data_out + 0x18A);
    xe::store_and_swap<uint32_t>(data_out + 0x18A, vendor_ptr);
  }

  // DEBUG
  /*
  auto xam = kernel_state()->GetKernelModule<XamModule>("xam.xex");
  if (!xam->xnet()) {
    auto xnet = new XNet(kernel_state());
    xnet->Initialize();

    xam->set_xnet(xnet);
  }
  */

  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_WSAStartup, kNetworking, kImplemented);

dword_result_t NetDll_WSAStartupEx_entry(dword_t caller, word_t version,
                                         pointer_t<X_WSADATA> data_ptr,
                                         dword_t versionReq) {
  return NetDll_WSAStartup_entry(caller, version, data_ptr);
}
DECLARE_XAM_EXPORT1(NetDll_WSAStartupEx, kNetworking, kImplemented);

dword_result_t NetDll_WSACleanup_entry(dword_t caller) {
  // This does nothing. Xenia needs WSA running.
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_WSACleanup, kNetworking, kImplemented);

// Instead of using dedicated storage for WSA error like on OS.
// Xbox shares space between normal error codes and WSA errors.
// This under the hood returns directly value received from RtlGetLastError.
dword_result_t NetDll_WSAGetLastError_entry() {
  return XThread::GetLastError();
}
DECLARE_XAM_EXPORT1(NetDll_WSAGetLastError, kNetworking, kImplemented);

dword_result_t NetDll_WSARecvFrom_entry(
    dword_t caller, dword_t socket, pointer_t<XWSABUF> buffers_ptr,
    dword_t buffer_count, lpdword_t num_bytes_recv, lpdword_t flags_ptr,
    pointer_t<XSOCKADDR_IN> from_addr, pointer_t<XWSAOVERLAPPED> overlapped_ptr,
    lpvoid_t completion_routine_ptr) {
  if (overlapped_ptr) {
    // auto evt = kernel_state()->object_table()->LookupObject<XEvent>(
    //    overlapped_ptr->event_handle);

    // if (evt) {
    //  //evt->Set(0, false);
    //}
  }

  // we're not going to be receiving packets any time soon
  // return error so we don't wait on that - Cancerous
  return -1;
}
DECLARE_XAM_EXPORT2(NetDll_WSARecvFrom, kNetworking, kStub, kHighFrequency);

// If the socket is a VDP socket, buffer 0 is the game data length, and buffer 1
// is the unencrypted game data.
dword_result_t NetDll_WSASendTo_entry(
    dword_t caller, dword_t socket_handle, pointer_t<XWSABUF> buffers,
    dword_t num_buffers, lpdword_t num_bytes_sent, dword_t flags,
    pointer_t<XSOCKADDR_IN> to_ptr, dword_t to_len,
    pointer_t<XWSAOVERLAPPED> overlapped, lpvoid_t completion_routine) {
  assert(!overlapped);
  assert(!completion_routine);

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  // Our sockets implementation doesn't support multiple buffers, so we need
  // to combine the buffers the game has given us!
  std::vector<uint8_t> combined_buffer_mem;
  uint32_t combined_buffer_size = 0;
  uint32_t combined_buffer_offset = 0;
  for (uint32_t i = 0; i < num_buffers; i++) {
    combined_buffer_size += buffers[i].len;
    combined_buffer_mem.resize(combined_buffer_size);
    uint8_t* combined_buffer = combined_buffer_mem.data();

    std::memcpy(combined_buffer + combined_buffer_offset,
                kernel_memory()->TranslateVirtual(buffers[i].buf_ptr),
                buffers[i].len);
    combined_buffer_offset += buffers[i].len;
  }

  N_XSOCKADDR_IN native_to(to_ptr);
  socket->SendTo(combined_buffer_mem.data(), combined_buffer_size, flags,
                 &native_to, to_len);

  // TODO: Instantly complete overlapped

  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_WSASendTo, kNetworking, kImplemented);

dword_result_t NetDll_WSAWaitForMultipleEvents_entry(dword_t num_events,
                                                     lpdword_t events,
                                                     dword_t wait_all,
                                                     dword_t timeout,
                                                     dword_t alertable) {
  if (num_events > 64) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSA_INVALID_PARAMETER));
    return ~0u;
  }

  uint64_t timeout_wait = (uint64_t)timeout;

  X_STATUS result = 0;
  do {
    result = xboxkrnl::xeNtWaitForMultipleObjectsEx(
        num_events, events, wait_all, 1, alertable,
        timeout != -1 ? &timeout_wait : nullptr);
  } while (result == X_STATUS_ALERTED);

  if (XFAILED(result)) {
    uint32_t error = xboxkrnl::xeRtlNtStatusToDosError(result);
    XThread::SetLastError(error);
    return ~0u;
  }
  return 0;
}
DECLARE_XAM_EXPORT2(NetDll_WSAWaitForMultipleEvents, kNetworking, kImplemented,
                    kBlocking);

dword_result_t NetDll_WSACreateEvent_entry() {
  XEvent* ev = new XEvent(kernel_state());
  ev->Initialize(true, false);
  return ev->handle();
}
DECLARE_XAM_EXPORT1(NetDll_WSACreateEvent, kNetworking, kImplemented);

dword_result_t NetDll_WSACloseEvent_entry(dword_t event_handle) {
  X_STATUS result = kernel_state()->object_table()->ReleaseHandle(event_handle);
  if (XFAILED(result)) {
    uint32_t error = xboxkrnl::xeRtlNtStatusToDosError(result);
    XThread::SetLastError(error);
    return 0;
  }
  return 1;
}
DECLARE_XAM_EXPORT1(NetDll_WSACloseEvent, kNetworking, kImplemented);

dword_result_t NetDll_WSAResetEvent_entry(dword_t event_handle) {
  X_STATUS result = xboxkrnl::xeNtClearEvent(event_handle);
  if (XFAILED(result)) {
    uint32_t error = xboxkrnl::xeRtlNtStatusToDosError(result);
    XThread::SetLastError(error);
    return 0;
  }
  return 1;
}
DECLARE_XAM_EXPORT1(NetDll_WSAResetEvent, kNetworking, kImplemented);

dword_result_t NetDll_WSASetEvent_entry(dword_t event_handle) {
  X_STATUS result = xboxkrnl::xeNtSetEvent(event_handle, nullptr);
  if (XFAILED(result)) {
    uint32_t error = xboxkrnl::xeRtlNtStatusToDosError(result);
    XThread::SetLastError(error);
    return 0;
  }
  return 1;
}
DECLARE_XAM_EXPORT1(NetDll_WSASetEvent, kNetworking, kImplemented);

struct XnAddrStatus {
  // Address acquisition is not yet complete
  static constexpr uint32_t XNET_GET_XNADDR_PENDING = 0x00000000;
  // XNet is uninitialized or no debugger found
  static constexpr uint32_t XNET_GET_XNADDR_NONE = 0x00000001;
  // Host has ethernet address (no IP address)
  static constexpr uint32_t XNET_GET_XNADDR_ETHERNET = 0x00000002;
  // Host has statically assigned IP address
  static constexpr uint32_t XNET_GET_XNADDR_STATIC = 0x00000004;
  // Host has DHCP assigned IP address
  static constexpr uint32_t XNET_GET_XNADDR_DHCP = 0x00000008;
  // Host has PPPoE assigned IP address
  static constexpr uint32_t XNET_GET_XNADDR_PPPOE = 0x00000010;
  // Host has one or more gateways configured
  static constexpr uint32_t XNET_GET_XNADDR_GATEWAY = 0x00000020;
  // Host has one or more DNS servers configured
  static constexpr uint32_t XNET_GET_XNADDR_DNS = 0x00000040;
  // Host is currently connected to online service
  static constexpr uint32_t XNET_GET_XNADDR_ONLINE = 0x00000080;
  // Network configuration requires troubleshooting
  static constexpr uint32_t XNET_GET_XNADDR_TROUBLESHOOT = 0x00008000;
};

// Port the guest reserved for System Link traffic, via XNetSetSystemLinkPort.
// 3074 is the Xbox default and what titles fall back to; it is only used to
// populate wPortOnline, not to bind anything here.
static std::atomic<uint16_t> system_link_port = {3074};

// Fill an XNADDR describing THIS console.
//
// This is the LAN-only reduction of upstream netplay's XLiveAPI::
// IpGetConsoleXnAddr. Everything that function does beyond these three fields
// is the Xbox Live path - an online IP from the web service and a Live logon
// check - and none of it is reachable without XLiveAPI, which does not build
// against Edge. See docs/netplay-port/README.md.
//
// abOnline IS filled now, as an SGADDR. Halo 3 refused every System Link join
// with "UNABLE TO JOIN - the party may have an incompatible network setup"
// while never opening its VDP peer socket, i.e. it judged us from the
// advertisement alone. An all-zero abOnline satisfies upstream's IsDeadSg, so
// every console we advertised looked like a dead secure address. See #19 s4.
static void GetConsoleXnAddr(XNADDR* addr_ptr) {
  std::memset(addr_ptr, 0, sizeof(XNADDR));

  // A stable per-console MAC out of XConfig's secured settings, NOT the host
  // NIC's. Titles use it as a console identity - RakNet derives its 64-bit
  // peer ids from it - so it has to survive a reboot and differ between
  // consoles. The old 0xCC fill did neither.
  std::memcpy(addr_ptr->abEnet, GetConsoleMacAddress().raw(),
              MacAddress::MacAddressSize);

  if (cvars::network_mode != NETWORK_MODE::LAN) {
    return;
  }

  const auto adapter_manager =
      kernel_state()->emulator()->GetNetworkAdapterManager();
  if (!adapter_manager || !adapter_manager->IsInterfaceSelected()) {
    return;
  }

  // ina is already in network byte order, which is what the guest expects.
  addr_ptr->ina = adapter_manager->GetSelectedAdapterLocalIP().sin_addr;
  addr_ptr->wPortOnline = system_link_port.load();

  // What upstream's IpGetConsoleXnAddr sets, plus a non-zero xbox_id.
  //
  // Upstream tags the platform and leaves xbox_id at zero, but its LAN peers
  // reach it through XLiveAPI, which fills the field elsewhere; we have no
  // such path, and a zero xbox_id with a zero SPI is precisely IsDeadSg. The
  // id is the SAME derivation NetDll_XNetXnAddrToMachineId applies to a peer's
  // MAC, so the value we advertise for ourselves is the value the other
  // console computes for us rather than a second, disagreeing identity.
  //
  // security_parameter_index stays zero: it is assigned by a real Security
  // Gateway, there is no gateway on a LAN, and a fabricated one would be a
  // guess. xbox_id alone already makes IsDeadSg false.
  addr_ptr->abOnline.platform_type = PLATFORM_TYPE::Xbox360;
  addr_ptr->abOnline.xbox_id =
      GetMachineId(GetConsoleMacAddress().to_uint64());
}

dword_result_t NetDll_XNetGetTitleXnAddr_entry(dword_t caller,
                                               pointer_t<XNADDR> addr_ptr) {
  GetConsoleXnAddr(addr_ptr);

  uint32_t status = XnAddrStatus::XNET_GET_XNADDR_ETHERNET;
  if (cvars::network_mode == NETWORK_MODE::LAN && addr_ptr->ina.s_addr) {
    // STATIC because the address is the one we hand out and will keep handing
    // out; DHCP would invite the title to wait for a lease that never changes.
    status |= XnAddrStatus::XNET_GET_XNADDR_STATIC |
              XnAddrStatus::XNET_GET_XNADDR_GATEWAY |
              XnAddrStatus::XNET_GET_XNADDR_DNS;
  } else {
    // Titles branch on TROUBLESHOOT to show "check your network" rather than
    // hanging on a discovery that cannot answer.
    status |= XnAddrStatus::XNET_GET_XNADDR_TROUBLESHOOT;
  }

  // Titles poll this every frame - Halo 3 managed 1555 calls in 25 seconds -
  // so log only when the answer actually changes. Logging every call buried
  // the rest of the netplay trace under tens of MB.
  static std::atomic<uint32_t> last_status = {0xFFFFFFFF};
  static std::atomic<uint32_t> last_ina = {0};
  const uint32_t ina = addr_ptr->ina.s_addr;
  if (last_status.exchange(status) != status || last_ina.exchange(ina) != ina) {
    XELOGI("XNetGetTitleXnAddr: mode={} ina={} port={} -> status {:08X}",
           cvars::network_mode, ip_to_string(addr_ptr->ina),
           uint16_t(addr_ptr->wPortOnline), status);
  }

  return status;
}

DECLARE_XAM_EXPORT1(NetDll_XNetGetTitleXnAddr, kNetworking, kImplemented);

dword_result_t NetDll_XNetGetDebugXnAddr_entry(dword_t caller,
                                               pointer_t<XNADDR> addr_ptr) {
  addr_ptr.Zero();

  // XNET_GET_XNADDR_NONE causes caller to gracefully return.
  return XnAddrStatus::XNET_GET_XNADDR_NONE;
}
DECLARE_XAM_EXPORT1(NetDll_XNetGetDebugXnAddr, kNetworking, kStub);

dword_result_t NetDll_XNetXnAddrToMachineId_entry(dword_t caller,
                                                  pointer_t<XNADDR> addr_ptr,
                                                  lpqword_t id_ptr) {
  if (cvars::network_mode != NETWORK_MODE::LAN) {
    // Non-zero: not signed in, which is what the stub always claimed.
    return 1;
  }

  // Derived from the peer's MAC, so the same console yields the same id on
  // every lookup and on both ends of the link. A peer we only know by IP has
  // no MAC, so it has no machine id either - saying otherwise would hand two
  // different consoles the id 0.
  const MacAddress mac(addr_ptr->abEnet);
  if (!mac.to_uint64()) {
    return uint32_t(X_WSAError::X_WSAEINVAL);
  }

  *id_ptr = GetMachineId(mac.to_uint64());

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetXnAddrToMachineId, kNetworking, kImplemented);

dword_result_t XNetLogonGetTitleID_entry(dword_t caller, lpvoid_t params) {
  return kernel_state()->title_id();
}
DECLARE_XAM_EXPORT1(XNetLogonGetTitleID, kNetworking, kImplemented);

// This console's own machine id. Halo 3 imports it and it had NO
// implementation behind it at all - "!!" in the import table on both consoles.
//
// An unimplemented import is worse than a stub for diagnosis: xex_module warns
// once at module load and installs a null handler, so there is no per-call log
// line at ANY log level and "grep says it is never called" proves nothing. It
// is implemented here partly to find out whether the title calls it.
//
// The value is the SAME derivation NetDll_XNetXnAddrToMachineId applies to a
// peer's MAC, so the id a console reports for itself is the id the other
// console computes for it. Halo identifies session members by machine id, and
// an id that is absent - or worse, identical on every console, which is the
// shape the zero MAC and the constant XNKID both had - would make two consoles
// look like one machine.
dword_result_t XNetLogonGetMachineID_entry(lpqword_t machine_id_ptr) {
  if (!machine_id_ptr) {
    return uint32_t(X_WSAError::X_WSAEFAULT);
  }

  const uint64_t machine_id = GetLocalMachineId(GetConsoleMacAddress());
  *machine_id_ptr = machine_id;

  static std::atomic<bool> logged = {false};
  if (!logged.exchange(true)) {
    XELOGI("XNetLogonGetMachineID: {:016X}", machine_id);
  }

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(XNetLogonGetMachineID, kNetworking, kImplemented);

// The other two netplay imports Halo 3 wants and we did not provide. Both are
// upstream's shapes. Same reasoning as above: implemented as much to make them
// visible in a trace as to make them work.
dword_result_t NetDll_XNetUnregisterInAddr_entry(dword_t caller,
                                                 dword_t addr) {
  // The mapping XNetXnAddrToInAddr hands out is the identity on a LAN, so
  // there is nothing held to release.
  XELOGI("XNetUnregisterInAddr({:08X})", addr.value());
  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetUnregisterInAddr, kNetworking, kStub);

dword_result_t NetDll_XNetServerToInAddr_entry(dword_t caller,
                                               dword_t server_addr,
                                               dword_t service_id,
                                               pointer_t<in_addr> pina) {
  if (!pina) {
    return uint32_t(X_WSAError::X_WSAEFAULT);
  }
  if (!server_addr || !service_id) {
    return uint32_t(X_WSAError::X_WSAEINVAL);
  }

  pina->s_addr = htonl(server_addr);

  XELOGI("XNetServerToInAddr: service {:08X} -> {}", service_id.value(),
         ip_to_string(*pina));

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetServerToInAddr, kNetworking, kSketchy);

void NetDll_XNetInAddrToString_entry(dword_t caller, dword_t in_addr,
                                     lpstring_t string_out,
                                     dword_t string_size) {
  strncpy(string_out, "666.666.666.666", string_size);
}
DECLARE_XAM_EXPORT1(NetDll_XNetInAddrToString, kNetworking, kStub);

// This converts a XNet address to an IN_ADDR. The IN_ADDR is used for
// subsequent socket calls (like a handle to a XNet address)
dword_result_t NetDll_XNetXnAddrToInAddr_entry(dword_t caller,
                                               pointer_t<XNADDR> xn_addr,
                                               lpvoid_t xid,
                                               pointer_t<in_addr> in_addr) {
  in_addr.Zero();

  // On a real console the returned IN_ADDR is an opaque handle that the XNet
  // layer maps back to a secure address. On a LAN there is nothing to secure
  // and nothing to translate: the peer's ina IS routable from here, so the
  // mapping is the identity. That is also what upstream netplay does in LAN
  // mode, so a future port of its session layer keeps working.
  if (cvars::network_mode != NETWORK_MODE::LAN) {
    return uint32_t(X_WSAError::X_WSAEINVAL);
  }

  // Our own address must come back as something we can bind and talk to
  // locally - a title that resolves itself and then sends to the LAN address
  // would be shouting at the router to reach itself.
  if (GetConsoleMacAddress() == MacAddress(xn_addr->abEnet)) {
    in_addr->s_addr = htonl(INADDR_LOOPBACK);
    XELOGI("XNetXnAddrToInAddr: self -> loopback");
    return X_ERROR_SUCCESS;
  }

  in_addr->s_addr = xn_addr->ina.s_addr;

  XELOGI("XNetXnAddrToInAddr: peer -> {}", ip_to_string(*in_addr));

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetXnAddrToInAddr, kNetworking, kSketchy);

// Does the reverse of the above.
dword_result_t NetDll_XNetInAddrToXnAddr_entry(dword_t caller, dword_t in_addr,
                                               pointer_t<XNADDR> xn_addr,
                                               lpvoid_t xid) {
  if (xn_addr) {
    std::memset(xn_addr, 0, sizeof(XNADDR));
  }

  if (cvars::network_mode != NETWORK_MODE::LAN) {
    return uint32_t(X_WSAError::X_WSAEINVAL);
  }

  // Loopback and broadcast both mean "this console" to a title asking who it
  // is - broadcast because discovery resolves the address it just shouted at.
  if (in_addr == LOOPBACK || in_addr == BROADCAST) {
    GetConsoleXnAddr(xn_addr);
    return X_ERROR_SUCCESS;
  }

  // A peer we have only ever seen as an IP. We know its address and nothing
  // else; abEnet stays zero because inventing a MAC here would collide with a
  // real one and make two consoles look like the same machine.
  xn_addr->ina.s_addr = htonl(in_addr);
  xn_addr->wPortOnline = system_link_port.load();
  // Upstream tags the platform on this branch too. xbox_id stays zero: it is
  // derived from a MAC and we do not have this peer's.
  xn_addr->abOnline.platform_type = PLATFORM_TYPE::Xbox360;

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetInAddrToXnAddr, kNetworking, kSketchy);

// https://www.google.com/patents/WO2008112448A1?cl=en
// Reserves a port for use by system link
dword_result_t NetDll_XNetSetSystemLinkPort_entry(dword_t caller,
                                                  dword_t port) {
  // The guest passes this already byte-swapped, as it would go on the wire.
  const uint16_t host_port = xe::byte_swap(static_cast<uint16_t>(port));
  system_link_port.store(host_port);

  XELOGI("XNetSetSystemLinkPort: {}", host_port);

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetSetSystemLinkPort, kNetworking, kImplemented);

// Was an unimplemented import. Mirrors the setter's convention exactly: the
// guest handed us the port already swapped, so give it back the same way.
dword_result_t NetDll_XNetGetSystemLinkPort_entry(dword_t caller,
                                                  lpdword_t port_ptr) {
  if (!port_ptr) {
    return uint32_t(X_WSAError::X_WSAEINVAL);
  }

  *port_ptr = xe::byte_swap(system_link_port.load());

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetGetSystemLinkPort, kNetworking, kImplemented);

// https://github.com/ILOVEPIE/Cxbx-Reloaded/blob/master/src/CxbxKrnl/EmuXOnline.h#L39
struct XEthernetStatus {
  static constexpr uint32_t XNET_ETHERNET_LINK_ACTIVE = 0x01;
  static constexpr uint32_t XNET_ETHERNET_LINK_100MBPS = 0x02;
  static constexpr uint32_t XNET_ETHERNET_LINK_10MBPS = 0x04;
  static constexpr uint32_t XNET_ETHERNET_LINK_FULL_DUPLEX = 0x08;
  static constexpr uint32_t XNET_ETHERNET_LINK_HALF_DUPLEX = 0x10;
};

// *** THIS IS THE GATE ON EVERYTHING ELSE. ***
//
// Returning 0 here means "no cable". Halo 3 polls this in a tight loop -
// MEASURED at 34,228 calls in 25 seconds while its System Link browser was
// open - and never proceeds to create a socket, because as far as the title is
// concerned the console is not plugged into anything. Every downstream symptom
// (no socket, no bind, no discovery traffic, an empty browser that never
// errors) came from this one return value.
dword_result_t NetDll_XNetGetEthernetLinkStatus_entry(dword_t caller) {
  if (cvars::network_mode == NETWORK_MODE::OFFLINE) {
    return 0;
  }

  const auto adapter_manager =
      kernel_state()->emulator()->GetNetworkAdapterManager();
  if (!adapter_manager || !adapter_manager->IsInterfaceSelected()) {
    // Genuinely no usable interface - report the cable out rather than lie,
    // so a title shows "check your connection" instead of hanging.
    return 0;
  }

  return XEthernetStatus::XNET_ETHERNET_LINK_ACTIVE |
         XEthernetStatus::XNET_ETHERNET_LINK_100MBPS |
         XEthernetStatus::XNET_ETHERNET_LINK_FULL_DUPLEX;
}
DECLARE_XAM_EXPORT2(NetDll_XNetGetEthernetLinkStatus, kNetworking, kImplemented,
                    kHighFrequency);

dword_result_t NetDll_XNetDnsLookup_entry(dword_t caller, lpstring_t host,
                                          dword_t event_handle,
                                          lpdword_t pdns) {
  // TODO(gibbed): actually implement this
  if (pdns) {
    auto dns_guest = kernel_memory()->SystemHeapAlloc(sizeof(XNDNS));
    auto dns = kernel_memory()->TranslateVirtual<XNDNS*>(dns_guest);
    dns->status = 1;  // non-zero = error
    *pdns = dns_guest;
  }
  if (event_handle) {
    auto ev =
        kernel_state()->object_table()->LookupObject<XEvent>(event_handle);
    assert_not_null(ev);
    ev->Set(0, false);
  }
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetDnsLookup, kNetworking, kStub);

dword_result_t NetDll_XNetDnsRelease_entry(dword_t caller,
                                           pointer_t<XNDNS> dns) {
  if (!dns) {
    return X_STATUS_INVALID_PARAMETER;
  }
  kernel_memory()->SystemHeapFree(dns.guest_address());
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetDnsRelease, kNetworking, kStub);

// ---------------------------------------------------------------------------
// QoS
// ---------------------------------------------------------------------------
// On a real console QoS is served by the XNet layer, not by the title: a host
// registers a payload once with XNetQosListen and the system answers probes
// with it for as long as the session is up. A joining console calls
// XNetQosLookup, gets the payload plus a round-trip time, and decides from it
// whether the party is joinable.
//
// MEASURED, 2026-08-16, both consoles at log_level 3: the host hands
// XNetQosListen 173 bytes with flags=0x05 (ENABLE|SET_DATA) and the old stub
// returned X_ERROR_FUNCTION_FAILED and stored NOTHING, while XNetQosLookup and
// XNetQosGetListenStats were unimplemented imports on both sides. #20 5.1.
//
// Upstream netplay serves all of this out of XLiveAPI over HTTP, which does not
// exist on a LAN and does not build against Edge. So the exchange here is a
// direct console-to-console one on kQosProbePort. It only ever has to
// interoperate with another Xenra instance - the same position System Link
// discovery is already in - so the packet format below is ours.
enum XNET_QOS : uint32_t {
  XNET_QOS_LISTEN_ENABLE = 0x01,
  XNET_QOS_LISTEN_DISABLE = 0x02,
  XNET_QOS_LISTEN_SET_DATA = 0x04,
  XNET_QOS_LISTEN_SET_BITSPERSEC = 0x08,
  XNET_QOS_LISTEN_RELEASE = 0x10,
};

enum XNET_XNQOSINFO_FLAGS : uint8_t {
  XNET_XNQOSINFO_COMPLETE = 0x01,
  XNET_XNQOSINFO_TARGET_CONTACTED = 0x02,
  XNET_XNQOSINFO_TARGET_DISABLED = 0x04,
  XNET_XNQOSINFO_DATA_RECEIVED = 0x08,
  XNET_XNQOSINFO_PARTIAL_COMPLETE = 0x10,
};

struct XNQOSLISTENSTATS {
  xe::be<uint32_t> size_of_struct;
  xe::be<uint32_t> requests_received_count;
  xe::be<uint32_t> probes_received_count;
  xe::be<uint32_t> slots_full_discards_count;
  xe::be<uint32_t> data_replies_sent_count;
  xe::be<uint32_t> data_reply_bytes_sent;
  xe::be<uint32_t> probe_replies_sent_count;
};
static_assert_size(XNQOSLISTENSTATS, 0x1C);

#ifdef XE_PLATFORM_WIN32
using qos_socket_t = SOCKET;
using qos_socklen_t = int;
static const qos_socket_t kInvalidQosSocket = INVALID_SOCKET;
static void CloseQosSocket(qos_socket_t s) { closesocket(s); }
#else
using qos_socket_t = int;
using qos_socklen_t = socklen_t;
static const qos_socket_t kInvalidQosSocket = -1;
static void CloseQosSocket(qos_socket_t s) { close(s); }
#endif

// Ours, not Microsoft's. Above 1024 so it needs no privileges and is not
// touched by XSocket's guest-port remap.
static constexpr uint16_t kQosProbePort = 13000;

// magic[4] | version | type | data_len(BE16) | session id(BE64) | data
static constexpr uint8_t kQosMagic[4] = {'X', 'Q', 'O', 'S'};
static constexpr uint8_t kQosVersion = 1;
static constexpr size_t kQosHeaderSize = 16;
static constexpr uint8_t kQosTypeProbe = 0;
static constexpr uint8_t kQosTypeReply = 1;

struct QosListenEntry {
  bool enabled = false;
  uint32_t bits_per_second = 0;
  std::vector<uint8_t> data;
};

static std::mutex qos_listen_mutex;
static std::map<uint64_t, QosListenEntry> qos_listeners;

// XNetQosGetListenStats is a diagnostic on real hardware; a title that polls it
// is asking whether anyone is probing. Counting for real costs nothing and is
// the difference between "nobody asked us" and "we answered and were rejected".
static std::atomic<uint32_t> qos_requests_received = {0};
static std::atomic<uint32_t> qos_probes_received = {0};
static std::atomic<uint32_t> qos_data_replies_sent = {0};
static std::atomic<uint32_t> qos_data_reply_bytes = {0};
static std::atomic<uint32_t> qos_probe_replies_sent = {0};

static void BuildQosHeader(uint8_t* out, uint8_t type, uint64_t session_id,
                           uint16_t data_len) {
  std::memcpy(out, kQosMagic, sizeof(kQosMagic));
  out[4] = kQosVersion;
  out[5] = type;
  out[6] = static_cast<uint8_t>(data_len >> 8);
  out[7] = static_cast<uint8_t>(data_len & 0xFF);
  for (int i = 0; i < 8; ++i) {
    out[8 + i] = static_cast<uint8_t>((session_id >> ((7 - i) * 8)) & 0xFF);
  }
}

static bool ParseQosHeader(const uint8_t* data, size_t length, uint8_t* out_type,
                           uint64_t* out_session_id, uint16_t* out_data_len) {
  if (length < kQosHeaderSize) {
    return false;
  }
  if (std::memcmp(data, kQosMagic, sizeof(kQosMagic)) != 0 ||
      data[4] != kQosVersion) {
    return false;
  }
  *out_type = data[5];
  *out_data_len = static_cast<uint16_t>((data[6] << 8) | data[7]);
  uint64_t session_id = 0;
  for (int i = 0; i < 8; ++i) {
    session_id = (session_id << 8) | data[8 + i];
  }
  *out_session_id = session_id;
  return true;
}

static std::atomic<bool> qos_responder_running = {false};

// One responder per process, started the first time a title enables listening
// and left running for the life of the emulator. A title that leaves and
// re-enters matchmaking would otherwise pay a bind/teardown race on the same
// port, and the registry it answers from is already keyed by session.
static void QosResponderThread() {
  xe::threading::set_name("XNet QoS Responder");

  qos_socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock == kInvalidQosSocket) {
    XELOGE("XNet QoS: responder could not open a socket");
    qos_responder_running.store(false);
    return;
  }

  int reuse = 1;
  setsockopt(sock, SOL_SOCKET, SO_REUSEADDR,
             reinterpret_cast<const char*>(&reuse), sizeof(reuse));

  sockaddr_in bind_addr = {};
  bind_addr.sin_family = AF_INET;
  bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);
  bind_addr.sin_port = htons(kQosProbePort);
  if (bind(sock, reinterpret_cast<sockaddr*>(&bind_addr), sizeof(bind_addr)) !=
      0) {
    XELOGE("XNet QoS: responder could not bind UDP {}", kQosProbePort);
    CloseQosSocket(sock);
    qos_responder_running.store(false);
    return;
  }

  XELOGI("XNet QoS: responder listening on UDP {}", kQosProbePort);

  std::vector<uint8_t> in_buffer(1500);
  std::vector<uint8_t> out_buffer;
  while (true) {
    sockaddr_in from = {};
    qos_socklen_t from_len = sizeof(from);
    const int received =
        static_cast<int>(recvfrom(sock, reinterpret_cast<char*>(in_buffer.data()),
                                  static_cast<int>(in_buffer.size()), 0,
                                  reinterpret_cast<sockaddr*>(&from), &from_len));
    if (received <= 0) {
      continue;
    }

    uint8_t type = 0;
    uint64_t session_id = 0;
    uint16_t data_len = 0;
    if (!ParseQosHeader(in_buffer.data(), static_cast<size_t>(received), &type,
                        &session_id, &data_len) ||
        type != kQosTypeProbe) {
      continue;
    }

    qos_requests_received.fetch_add(1);
    qos_probes_received.fetch_add(1);

    std::vector<uint8_t> payload;
    bool enabled = false;
    {
      std::lock_guard<std::mutex> lock(qos_listen_mutex);
      auto it = qos_listeners.find(session_id);
      if (it != qos_listeners.end()) {
        enabled = it->second.enabled;
        payload = it->second.data;
      }
    }

    if (!enabled) {
      // Answering "not listening" is a real answer - it is how a joining
      // console learns the party is gone rather than timing out on it.
      XELOGD("XNet QoS: probe for {:016X} from {}, not listening", session_id,
             ip_to_string(from.sin_addr));
      out_buffer.assign(kQosHeaderSize, 0);
      BuildQosHeader(out_buffer.data(), kQosTypeReply, session_id, 0);
      sendto(sock, reinterpret_cast<const char*>(out_buffer.data()),
             static_cast<int>(out_buffer.size()), 0,
             reinterpret_cast<sockaddr*>(&from), from_len);
      qos_probe_replies_sent.fetch_add(1);
      continue;
    }

    out_buffer.assign(kQosHeaderSize + payload.size(), 0);
    BuildQosHeader(out_buffer.data(), kQosTypeReply, session_id,
                   static_cast<uint16_t>(payload.size()));
    if (!payload.empty()) {
      std::memcpy(out_buffer.data() + kQosHeaderSize, payload.data(),
                  payload.size());
    }

    sendto(sock, reinterpret_cast<const char*>(out_buffer.data()),
           static_cast<int>(out_buffer.size()), 0,
           reinterpret_cast<sockaddr*>(&from), from_len);

    qos_probe_replies_sent.fetch_add(1);
    if (!payload.empty()) {
      qos_data_replies_sent.fetch_add(1);
      qos_data_reply_bytes.fetch_add(static_cast<uint32_t>(payload.size()));
    }

    XELOGD("XNet QoS: answered probe for {:016X} from {} with {} bytes",
           session_id, ip_to_string(from.sin_addr), payload.size());
  }
}

static void EnsureQosResponder() {
  bool expected = false;
  if (!qos_responder_running.compare_exchange_strong(expected, true)) {
    return;
  }
  std::thread(QosResponderThread).detach();
}

// Sends probes_count probes to one peer and waits for the first reply. Returns
// the measured round trip in milliseconds, or -1 if nobody answered.
static int32_t ProbeQosPeer(uint32_t peer_ip_net_order, uint64_t session_id,
                            uint32_t probes_count,
                            std::vector<uint8_t>* out_data) {
  qos_socket_t sock = socket(AF_INET, SOCK_DGRAM, 0);
  if (sock == kInvalidQosSocket) {
    return -1;
  }

  // cfgQosProbeTimeoutInSeconds is the console's own budget for this, and the
  // title has already told us what it is.
  const uint32_t timeout_seconds =
      xnet_startup_params.cfgQosProbeTimeoutInSeconds
          ? xnet_startup_params.cfgQosProbeTimeoutInSeconds
          : 2;
#ifdef XE_PLATFORM_WIN32
  DWORD timeout = timeout_seconds * 1000;
#else
  timeval timeout = {};
  timeout.tv_sec = timeout_seconds;
#endif
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO,
             reinterpret_cast<const char*>(&timeout), sizeof(timeout));

  sockaddr_in peer = {};
  peer.sin_family = AF_INET;
  peer.sin_addr.s_addr = peer_ip_net_order;
  peer.sin_port = htons(kQosProbePort);

  uint8_t probe[kQosHeaderSize];
  BuildQosHeader(probe, kQosTypeProbe, session_id, 0);

  std::vector<uint8_t> reply(1500);
  const uint32_t attempts = std::max(probes_count, uint32_t(1));
  for (uint32_t attempt = 0; attempt < attempts; ++attempt) {
    const auto sent_at = std::chrono::steady_clock::now();
    if (sendto(sock, reinterpret_cast<const char*>(probe), sizeof(probe), 0,
               reinterpret_cast<sockaddr*>(&peer), sizeof(peer)) < 0) {
      break;
    }

    const int received = static_cast<int>(
        recv(sock, reinterpret_cast<char*>(reply.data()),
             static_cast<int>(reply.size()), 0));
    if (received < static_cast<int>(kQosHeaderSize)) {
      continue;
    }

    uint8_t type = 0;
    uint64_t reply_session = 0;
    uint16_t data_len = 0;
    if (!ParseQosHeader(reply.data(), static_cast<size_t>(received), &type,
                        &reply_session, &data_len) ||
        type != kQosTypeReply || reply_session != session_id) {
      continue;
    }

    const auto rtt = std::chrono::duration_cast<std::chrono::milliseconds>(
                         std::chrono::steady_clock::now() - sent_at)
                         .count();

    if (data_len &&
        static_cast<size_t>(received) >= kQosHeaderSize + data_len) {
      out_data->assign(reply.data() + kQosHeaderSize,
                       reply.data() + kQosHeaderSize + data_len);
    }

    CloseQosSocket(sock);
    return static_cast<int32_t>(rtt);
  }

  CloseQosSocket(sock);
  return -1;
}

dword_result_t NetDll_XNetQosServiceLookup_entry(dword_t caller, dword_t flags,
                                                 dword_t event_handle,
                                                 lpdword_t pqos) {
  // Set pqos as some games will try accessing it despite non-successful result
  if (pqos) {
    auto qos_guest = kernel_memory()->SystemHeapAlloc(sizeof(XNQOS));
    auto qos = kernel_memory()->TranslateVirtual<XNQOS*>(qos_guest);
    qos->count = qos->count_pending = 0;
    *pqos = qos_guest;
  }
  if (event_handle) {
    auto ev =
        kernel_state()->object_table()->LookupObject<XEvent>(event_handle);
    assert_not_null(ev);
    ev->Set(0, false);
  }
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetQosServiceLookup, kNetworking, kStub);

dword_result_t NetDll_XNetQosRelease_entry(dword_t caller,
                                           pointer_t<XNQOS> qos) {
  if (!qos) {
    return X_STATUS_INVALID_PARAMETER;
  }

  // Each answered probe carried a payload we allocated on the system heap and
  // handed the guest a pointer to. XNetQosServiceLookup's empty result has
  // count 0, so this is a no-op there.
  const uint32_t count = qos->count;
  for (uint32_t i = 0; i < count; ++i) {
    const XNQOSINFO& info = qos->info[i];
    if (info.data_ptr && (info.flags & XNET_XNQOSINFO_DATA_RECEIVED)) {
      kernel_memory()->SystemHeapFree(uint32_t(info.data_ptr));
    }
  }

  kernel_memory()->SystemHeapFree(qos.guest_address());
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetQosRelease, kNetworking, kStub);

static uint64_t ReadSessionId(const uint8_t* be_bytes) {
  uint64_t session_id = 0;
  for (int i = 0; i < 8; ++i) {
    session_id = (session_id << 8) | be_bytes[i];
  }
  return session_id;
}

dword_result_t NetDll_XNetQosListen_entry(dword_t caller, lpvoid_t id,
                                          lpvoid_t data, dword_t data_size,
                                          dword_t bits_per_second,
                                          dword_t flags) {
  if (!id) {
    return X_ERROR_SUCCESS;
  }

  const uint64_t session_id = ReadSessionId(id.as<const uint8_t*>());

  XELOGI("XNetQosListen: session {:016X}, {} bytes, {} bits/sec, flags {:08X}",
         session_id, data_size.value(), bits_per_second.value(), flags.value());

  // The old stub returned X_ERROR_FUNCTION_FAILED, which is a title-visible
  // "this console cannot host". Everything below is best-effort on a LAN and
  // there is nothing here that can fail in a way the title should hear about.
  std::lock_guard<std::mutex> lock(qos_listen_mutex);

  if (flags & XNET_QOS_LISTEN_RELEASE) {
    qos_listeners.erase(session_id);
    XELOGI("XNetQosListen: released {:016X}", session_id);
    return X_ERROR_SUCCESS;
  }

  auto& entry = qos_listeners[session_id];

  if (flags & XNET_QOS_LISTEN_ENABLE) {
    entry.enabled = true;
    EnsureQosResponder();
  }
  if (flags & XNET_QOS_LISTEN_DISABLE) {
    entry.enabled = false;
  }
  if (flags & XNET_QOS_LISTEN_SET_BITSPERSEC) {
    entry.bits_per_second = bits_per_second.value();
  }
  if ((flags & XNET_QOS_LISTEN_SET_DATA) && data && data_size) {
    // cfgQosDataLimitDiv4 is the console's own cap. Upstream assert_always()s
    // past it; a truncated payload is worse than a rejected one, so refuse.
    const uint32_t limit =
        xnet_startup_params.cfgQosDataLimitDiv4
            ? uint32_t(xnet_startup_params.cfgQosDataLimitDiv4) * 4
            : 256;
    if (data_size > limit) {
      XELOGW("XNetQosListen: {} bytes exceeds the {}-byte QoS data limit",
             data_size.value(), limit);
      return X_ERROR_SUCCESS;
    }

    const uint8_t* payload = data.as<const uint8_t*>();
    entry.data.assign(payload, payload + data_size);
    XELOGI("XNetQosListen: stored {} bytes for {:016X}: {}", data_size.value(),
           session_id, HexDumpPacket(payload, data_size.value()));
  }

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetQosListen, kNetworking, kSketchy);

// The joining half of the above: probe each remote console named by the title
// and hand back what it answered with. Was an unimplemented import - "!!" in
// Halo 3's import table on both consoles - so a title that asked what the party
// looked like got nothing back at all.
dword_result_t NetDll_XNetQosLookup_entry(
    dword_t caller, dword_t num_remote_consoles,
    lpvoid_t remote_addresses_array_ptrs, lpvoid_t session_ids_array_ptrs,
    lpvoid_t remote_keys_array_ptrs, dword_t num_gateways,
    lpvoid_t gateways_array, lpvoid_t service_ids_array, dword_t probes_count,
    dword_t bits_per_second, dword_t flags, dword_t event_handle,
    lpdword_t qos_ptr) {
  XELOGI("XNetQosLookup: {} consoles, {} gateways, {} probes",
         num_remote_consoles.value(), num_gateways.value(),
         probes_count.value());

  if (!qos_ptr) {
    return uint32_t(X_WSAError::X_WSAEFAULT);
  }

  // One entry per remote console, plus one per gateway so the indices the title
  // reads back line up with the arrays it passed in. We have no security
  // gateway on a LAN, so those entries complete with no data.
  const uint32_t count = num_remote_consoles + num_gateways;

  struct QosTarget {
    uint64_t session_id = 0;
    uint32_t ip = 0;  // network byte order, 0 = nothing to probe
  };
  auto targets = std::make_shared<std::vector<QosTarget>>(count);

  auto* memory = kernel_memory();

  if (session_ids_array_ptrs) {
    const xe::be<uint32_t>* ptrs =
        session_ids_array_ptrs.as<const xe::be<uint32_t>*>();
    for (uint32_t i = 0; i < num_remote_consoles; ++i) {
      if (!ptrs[i]) {
        continue;
      }
      (*targets)[i].session_id = ReadSessionId(
          memory->TranslateVirtual<const uint8_t*>(uint32_t(ptrs[i])));
    }
  }

  if (remote_addresses_array_ptrs) {
    const xe::be<uint32_t>* ptrs =
        remote_addresses_array_ptrs.as<const xe::be<uint32_t>*>();
    for (uint32_t i = 0; i < num_remote_consoles; ++i) {
      if (!ptrs[i]) {
        continue;
      }
      const auto* xnaddr =
          memory->TranslateVirtual<const XNADDR*>(uint32_t(ptrs[i]));
      // ina is already in network byte order, the same field
      // XNetXnAddrToInAddr hands to the socket layer.
      (*targets)[i].ip = xnaddr->ina.s_addr;
    }
  }

  const uint32_t size = sizeof(XNQOS) + (sizeof(XNQOSINFO) * count);
  const uint32_t qos_address = memory->SystemHeapAlloc(size);
  if (!qos_address) {
    return uint32_t(X_WSAError::X_WSAEFAULT);
  }
  auto* qos = memory->TranslateVirtual<XNQOS*>(qos_address);
  std::memset(qos, 0, size);
  *qos_ptr = qos_address;

  // Titles poll count_pending to decide whether a lookup is still running; it
  // has to be non-zero on return or they spin issuing fresh lookups.
  qos->count_pending = count;

  auto run = [qos, count, targets, probes_count = probes_count.value(),
              event_handle = event_handle.value()]() {
    xe::threading::set_name("XNet QoS Lookup");

    for (uint32_t i = 0; i < count; ++i) {
      XNQOSINFO& info = qos->info[i];
      const auto& target = (*targets)[i];

      std::vector<uint8_t> data;
      int32_t rtt = -1;
      if (target.ip) {
        rtt = ProbeQosPeer(target.ip, target.session_id, probes_count, &data);
      }

      uint8_t info_flags = XNET_XNQOSINFO_COMPLETE;

      if (rtt >= 0) {
        info_flags |= XNET_XNQOSINFO_TARGET_CONTACTED;
        info.rtt_min_in_msecs = static_cast<uint16_t>(rtt);
        info.rtt_med_in_msecs = static_cast<uint16_t>(rtt);
        info.probes_xmit = static_cast<uint16_t>(std::max(probes_count, 1u));
        info.probes_recv = 1;
      } else {
        // Nobody answered. TARGET_DISABLED is what the title reads as "this
        // one is not accepting", which is true and is not the same claim as
        // "the network is broken".
        info_flags |= XNET_XNQOSINFO_TARGET_DISABLED;
        info.probes_xmit = static_cast<uint16_t>(std::max(probes_count, 1u));
        info.probes_recv = 0;
      }

      if (!data.empty()) {
        const uint32_t data_address = kernel_memory()->SystemHeapAlloc(
            static_cast<uint32_t>(data.size()));
        if (data_address) {
          std::memcpy(kernel_memory()->TranslateVirtual<uint8_t*>(data_address),
                      data.data(), data.size());
          info.data_ptr = data_address;
          info.data_len = static_cast<uint16_t>(data.size());
          info_flags |= XNET_XNQOSINFO_DATA_RECEIVED;
        }
      }

      info.up_bits_per_sec = 5 * 1024 * 1024;
      info.down_bits_per_sec = 5 * 1024 * 1024;
      info.flags = info_flags;

      qos->count_pending =
          std::max(int32_t(uint32_t(qos->count_pending)) - 1, 0);
      qos->count = uint32_t(qos->count) + 1;

      XELOGI("XNetQosLookup: {} of {} -> rtt {} ms, {} bytes", i + 1, count,
             rtt, data.size());
    }

    if (event_handle && uint32_t(qos->count) > 0) {
      xboxkrnl::xeNtSetEvent(event_handle, nullptr);
    }
  };

  // A probes_count of zero means the title wants the answer on return rather
  // than through the event - upstream found 5345081A relies on it.
  if (probes_count) {
    std::thread(run).detach();
  } else {
    XELOGI("XNetQosLookup: synchronous lookup");
    run();
  }

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetQosLookup, kNetworking, kSketchy);

dword_result_t NetDll_XNetQosGetListenStats_entry(
    dword_t caller, lpvoid_t session_id_ptr,
    pointer_t<XNQOSLISTENSTATS> qos_stats_ptr) {
  if (!qos_stats_ptr) {
    return X_ERROR_SUCCESS;
  }

  qos_stats_ptr->size_of_struct = sizeof(XNQOSLISTENSTATS);
  qos_stats_ptr->requests_received_count = qos_requests_received.load();
  qos_stats_ptr->probes_received_count = qos_probes_received.load();
  qos_stats_ptr->slots_full_discards_count = 0;
  qos_stats_ptr->data_replies_sent_count = qos_data_replies_sent.load();
  qos_stats_ptr->data_reply_bytes_sent = qos_data_reply_bytes.load();
  qos_stats_ptr->probe_replies_sent_count = qos_probe_replies_sent.load();

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetQosGetListenStats, kNetworking, kImplemented);

// The secure-link handshake a title performs before it will talk to a peer.
//
// Both were in xam_table.inc with NO implementation behind them, which is why
// Halo 3's import table printed them with "!!". Discovery never touches them;
// JOINING does, and a title that never sees CONNECTED concludes the peer is
// unreachable - "the party may have an incompatible network setup".
//
// There is no security gateway on a LAN and nothing to negotiate: the peer's
// address is already routable by the time XNetXnAddrToInAddr has run. So the
// link is up by definition, which is exactly what upstream netplay's stubs
// say too - see ref/kernel_xam_xam_net.cc.
enum XnetConnectStatus : uint32_t {
  XNET_CONNECT_STATUS_IDLE = 0x00,
  XNET_CONNECT_STATUS_PENDING = 0x01,
  XNET_CONNECT_STATUS_CONNECTED = 0x02,
};

dword_result_t NetDll_XNetConnect_entry(dword_t caller, dword_t addr) {
  XELOGI("XNetConnect({:08X})", addr.value());

  // Upstream sleeps here, with the note that 43430806, 43430821 and 5841124E
  // fail to connect without it - a title that polls GetConnectStatus in the
  // same breath can otherwise see CONNECTED before it has finished setting up
  // its own side. Kept, since it costs one join and cures a class of titles.
  xe::threading::Sleep(std::chrono::milliseconds(150));

  return X_ERROR_SUCCESS;
}
DECLARE_XAM_EXPORT1(NetDll_XNetConnect, kNetworking, kStub);

dword_result_t NetDll_XNetGetConnectStatus_entry(dword_t caller,
                                                 dword_t addr) {
  return XNET_CONNECT_STATUS_CONNECTED;
}
DECLARE_XAM_EXPORT1(NetDll_XNetGetConnectStatus, kNetworking, kStub);

dword_result_t NetDll_inet_addr_entry(lpstring_t addr_ptr) {
  if (!addr_ptr) {
    return -1;
  }

  uint32_t addr = inet_addr(addr_ptr);
  // https://docs.microsoft.com/en-us/windows/win32/api/winsock2/nf-winsock2-inet_addr#return-value
  // Based on console research it seems like x360 uses old version of inet_addr
  // In case of empty string it return 0 instead of -1
  if (addr == -1 && !addr_ptr.value().length()) {
    return 0;
  }

  return xe::byte_swap(addr);
}
DECLARE_XAM_EXPORT1(NetDll_inet_addr, kNetworking, kImplemented);

dword_result_t NetDll_socket_entry(dword_t caller, dword_t af, dword_t type,
                                   dword_t protocol) {
  XELOGI("NetDll_socket: af={}, type={}, protocol={}", af.value(), type.value(),
         protocol.value());

  if (!cvars::network_enabled) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENETDOWN));
    XELOGI("NetDll_socket: refused, network_enabled is off");
    return -1;
  }

  XSocket* socket = new XSocket(kernel_state());
  X_STATUS result = socket->Initialize(XSocket::AddressFamily((uint32_t)af),
                                       XSocket::Type((uint32_t)type),
                                       XSocket::Protocol((uint32_t)protocol));

  if (XFAILED(result)) {
    socket->Release();

    XThread::SetLastError(socket->GetLastWSAError());
    XELOGE("NetDll_socket: failed with error {:08X}",
           socket->GetLastWSAError());
    return -1;
  }

  return socket->handle();
}
DECLARE_XAM_EXPORT1(NetDll_socket, kNetworking, kImplemented);

dword_result_t NetDll_closesocket_entry(dword_t caller, dword_t socket_handle) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  // TODO: Absolutely delete this object. It is no longer valid after calling
  // closesocket.
  socket->Close();
  socket->ReleaseHandle();
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_closesocket, kNetworking, kImplemented);

int_result_t NetDll_shutdown_entry(dword_t caller, dword_t socket_handle,
                                   int_t how) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  auto ret = socket->Shutdown(how);
  if (ret == -1) {
    XThread::SetLastError(socket->GetLastWSAError());
  }
  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_shutdown, kNetworking, kImplemented);

dword_result_t NetDll_setsockopt_entry(dword_t caller, dword_t socket_handle,
                                       dword_t level, dword_t optname,
                                       lpvoid_t optval_ptr, dword_t optlen) {
  XELOGI("NetDll_setsockopt: socket={:08X}, level={:04X}, optname={:04X}",
         socket_handle.value(), level.value(), optname.value());

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  X_STATUS status = socket->SetOption(level, optname, optval_ptr, optlen);
  int result = XSUCCEEDED(status) ? 0 : -1;
  XELOGI("NetDll_setsockopt: {}, returning {}",
         XSUCCEEDED(status) ? "success" : "failed", result);
  return result;
}
DECLARE_XAM_EXPORT1(NetDll_setsockopt, kNetworking, kImplemented);

dword_result_t NetDll_getsockopt_entry(dword_t caller, dword_t socket_handle,
                                       dword_t level, dword_t optname,
                                       lpvoid_t optval_ptr, lpdword_t optlen) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  uint32_t native_len = *optlen;
  X_STATUS status = socket->GetOption(level, optname, optval_ptr, &native_len);
  return XSUCCEEDED(status) ? 0 : -1;
}
DECLARE_XAM_EXPORT1(NetDll_getsockopt, kNetworking, kImplemented);

dword_result_t NetDll_ioctlsocket_entry(dword_t caller, dword_t socket_handle,
                                        dword_t cmd, lpvoid_t arg_ptr) {
  XELOGI("NetDll_ioctlsocket: socket={:08X}, cmd={:08X}", socket_handle.value(),
         cmd.value());

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  X_STATUS status = socket->IOControl(cmd, arg_ptr);
  if (XFAILED(status)) {
    XThread::SetLastError(socket->GetLastWSAError());
    XELOGE("NetDll_ioctlsocket: failed with error {:08X}",
           socket->GetLastWSAError());
    return -1;
  }

  // TODO
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_ioctlsocket, kNetworking, kImplemented);

dword_result_t NetDll_bind_entry(dword_t caller, dword_t socket_handle,
                                 pointer_t<XSOCKADDR_IN> name,
                                 dword_t namelen) {
  XELOGI("NetDll_bind: socket={:08X}, namelen={}", socket_handle.value(),
         namelen.value());

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  N_XSOCKADDR_IN native_name(name);
  XELOGI(
      "NetDll_bind: calling socket->Bind, family={}, port={:04X}, addr={:08X}",
      native_name.sin_family, uint16_t(native_name.sin_port),
      uint32_t(native_name.sin_addr));
  X_STATUS status = socket->Bind(&native_name, namelen);
  if (XFAILED(status)) {
    XThread::SetLastError(socket->GetLastWSAError());
    XELOGE("NetDll_bind: failed with error {:08X}", socket->GetLastWSAError());
    return -1;
  }

  XELOGI("NetDll_bind: success, port={}", socket->bound_port());
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_bind, kNetworking, kImplemented);

dword_result_t NetDll_connect_entry(dword_t caller, dword_t socket_handle,
                                    pointer_t<XSOCKADDR> name,
                                    dword_t namelen) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  N_XSOCKADDR native_name(name);
  X_STATUS status = socket->Connect(&native_name, namelen);
  if (XFAILED(status)) {
    XThread::SetLastError(socket->GetLastWSAError());
    return -1;
  }

  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_connect, kNetworking, kImplemented);

dword_result_t NetDll_listen_entry(dword_t caller, dword_t socket_handle,
                                   int_t backlog) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  X_STATUS status = socket->Listen(backlog);
  if (XFAILED(status)) {
    XThread::SetLastError(socket->GetLastWSAError());
    return -1;
  }

  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_listen, kNetworking, kImplemented);

dword_result_t NetDll_accept_entry(dword_t caller, dword_t socket_handle,
                                   pointer_t<XSOCKADDR> addr_ptr,
                                   lpdword_t addrlen_ptr) {
  if (!addr_ptr) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAEFAULT));
    return -1;
  }

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  N_XSOCKADDR native_addr(addr_ptr);
  int native_len = *addrlen_ptr;
  auto new_socket = socket->Accept(&native_addr, &native_len);
  if (new_socket) {
    addr_ptr->address_family = native_addr.address_family;
    std::memcpy(addr_ptr->sa_data, native_addr.sa_data, *addrlen_ptr - 2);
    *addrlen_ptr = native_len;

    return new_socket->handle();
  } else {
    return -1;
  }
}
DECLARE_XAM_EXPORT1(NetDll_accept, kNetworking, kImplemented);

struct x_fd_set {
  xe::be<uint32_t> fd_count;
  xe::be<uint32_t> fd_array[64];
};

struct host_set {
  uint32_t count;
  object_ref<XSocket> sockets[64];

  void Load(const x_fd_set* guest_set) {
    assert_true(guest_set->fd_count < 64);
    this->count = guest_set->fd_count;
    for (uint32_t i = 0; i < this->count; ++i) {
      auto socket_handle = static_cast<X_HANDLE>(guest_set->fd_array[i]);
      if (socket_handle == -1) {
        this->count = i;
        break;
      }
      // Convert from Xenia -> native
      auto socket =
          kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
      assert_not_null(socket);
      this->sockets[i] = socket;
    }
  }

  void Store(x_fd_set* guest_set) {
    guest_set->fd_count = 0;
    for (uint32_t i = 0; i < this->count; ++i) {
      auto socket = this->sockets[i];
      guest_set->fd_array[guest_set->fd_count++] = socket->handle();
    }
  }

  void Store(fd_set* native_set) {
    FD_ZERO(native_set);
    for (uint32_t i = 0; i < this->count; ++i) {
      FD_SET(this->sockets[i]->native_handle(), native_set);
    }
  }

  void UpdateFrom(fd_set* native_set) {
    uint32_t new_count = 0;
    for (uint32_t i = 0; i < this->count; ++i) {
      auto socket = this->sockets[i];
      if (FD_ISSET(socket->native_handle(), native_set)) {
        this->sockets[new_count++] = socket;
      }
    }
    this->count = new_count;
  }
};

int_result_t NetDll_select_entry(dword_t caller, dword_t nfds,
                                 pointer_t<x_fd_set> readfds,
                                 pointer_t<x_fd_set> writefds,
                                 pointer_t<x_fd_set> exceptfds,
                                 lpvoid_t timeout_ptr) {
  XELOGD("NetDll_select: nfds={}, timeout={:08X}", nfds.value(),
         timeout_ptr.guest_address());

  host_set host_readfds = {0};
  fd_set native_readfds = {0};
  if (readfds) {
    host_readfds.Load(readfds);
    host_readfds.Store(&native_readfds);
  }
  host_set host_writefds = {0};
  fd_set native_writefds = {0};
  if (writefds) {
    host_writefds.Load(writefds);
    host_writefds.Store(&native_writefds);
  }
  host_set host_exceptfds = {0};
  fd_set native_exceptfds = {0};
  if (exceptfds) {
    host_exceptfds.Load(exceptfds);
    host_exceptfds.Store(&native_exceptfds);
  }
  timeval* timeout_in = nullptr;
  timeval timeout;
  if (timeout_ptr) {
    timeout = {static_cast<int32_t>(timeout_ptr.as_array<int32_t>()[0]),
               static_cast<int32_t>(timeout_ptr.as_array<int32_t>()[1])};
    Clock::ScaleGuestDurationTimeval(
        reinterpret_cast<int32_t*>(&timeout.tv_sec),
        reinterpret_cast<int32_t*>(&timeout.tv_usec));
    timeout_in = &timeout;
  }
  int ret = select(nfds, readfds ? &native_readfds : nullptr,
                   writefds ? &native_writefds : nullptr,
                   exceptfds ? &native_exceptfds : nullptr, timeout_in);
  if (readfds) {
    host_readfds.UpdateFrom(&native_readfds);
    host_readfds.Store(readfds);
  }
  if (writefds) {
    host_writefds.UpdateFrom(&native_writefds);
    host_writefds.Store(writefds);
  }
  if (exceptfds) {
    host_exceptfds.UpdateFrom(&native_exceptfds);
    host_exceptfds.Store(exceptfds);
  }

  // TODO(gibbed): modify ret to be what's actually copied to the guest fd_sets?
  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_select, kNetworking, kImplemented);

dword_result_t NetDll_recv_entry(dword_t caller, dword_t socket_handle,
                                 lpvoid_t buf_ptr, dword_t buf_len,
                                 dword_t flags) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  return socket->Recv(buf_ptr, buf_len, flags);
}
DECLARE_XAM_EXPORT1(NetDll_recv, kNetworking, kImplemented);

dword_result_t NetDll_recvfrom_entry(dword_t caller, dword_t socket_handle,
                                     lpvoid_t buf_ptr, dword_t buf_len,
                                     dword_t flags,
                                     pointer_t<XSOCKADDR_IN> from_ptr,
                                     lpdword_t fromlen_ptr) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  N_XSOCKADDR_IN native_from;
  if (from_ptr) {
    native_from = *from_ptr;
  }
  uint32_t native_fromlen = fromlen_ptr ? fromlen_ptr.value() : 0;
  int ret = socket->RecvFrom(buf_ptr, buf_len, flags, &native_from,
                             fromlen_ptr ? &native_fromlen : 0);

  if (from_ptr) {
    from_ptr->sin_family = native_from.sin_family;
    from_ptr->sin_port = native_from.sin_port;
    from_ptr->sin_addr = native_from.sin_addr;
    std::memset(from_ptr->x_sin_zero, 0, sizeof(from_ptr->x_sin_zero));
  }
  if (fromlen_ptr) {
    *fromlen_ptr = native_fromlen;
  }

  if (ret == -1) {
    XThread::SetLastError(socket->GetLastWSAError());
  } else if (ret > 0) {
    // Only log when we actually receive data
    const uint32_t from_ip = from_ptr ? uint32_t(from_ptr->sin_addr) : 0;
    XELOGD("NetDll_recvfrom: socket={:08X}, received {} bytes from {}.{}.{}.{}:{}",
           socket_handle.value(), ret, (from_ip >> 24) & 0xFF,
           (from_ip >> 16) & 0xFF, (from_ip >> 8) & 0xFF, from_ip & 0xFF,
           from_ptr ? uint16_t(from_ptr->sin_port) : 0);
    XELOGD("NetDll_recvfrom: payload {}",
           HexDumpPacket(buf_ptr.as<uint8_t*>(), static_cast<size_t>(ret)));
  }

  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_recvfrom, kNetworking, kImplemented);

dword_result_t NetDll_send_entry(dword_t caller, dword_t socket_handle,
                                 lpvoid_t buf_ptr, dword_t buf_len,
                                 dword_t flags) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  return socket->Send(buf_ptr, buf_len, flags);
}
DECLARE_XAM_EXPORT1(NetDll_send, kNetworking, kImplemented);

dword_result_t NetDll_sendto_entry(dword_t caller, dword_t socket_handle,
                                   lpvoid_t buf_ptr, dword_t buf_len,
                                   dword_t flags,
                                   pointer_t<XSOCKADDR_IN> to_ptr,
                                   dword_t to_len) {
  // Destination included deliberately. This line used to print only the socket
  // and the length, which is why the Bind/SendTo port-mapping asymmetry needed
  // a packet capture from a second machine to find at all - the log could not
  // have shown it. #19 4.4.
  const uint32_t to_ip = to_ptr ? uint32_t(to_ptr->sin_addr) : 0;
  const uint16_t to_port = to_ptr ? uint16_t(to_ptr->sin_port) : 0;
  XELOGD("NetDll_sendto: socket={:08X}, len={}, to={}.{}.{}.{}:{}",
         socket_handle.value(), buf_len.value(), (to_ip >> 24) & 0xFF,
         (to_ip >> 16) & 0xFF, (to_ip >> 8) & 0xFF, to_ip & 0xFF, to_port);
  if (buf_ptr) {
    XELOGD("NetDll_sendto: payload {}",
           HexDumpPacket(buf_ptr.as<uint8_t*>(),
                         static_cast<size_t>(buf_len.value())));
  }

  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  N_XSOCKADDR_IN native_to(to_ptr);
  int ret = socket->SendTo(buf_ptr, buf_len, flags, &native_to, to_len);
  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_sendto, kNetworking, kImplemented);

dword_result_t NetDll_WSAEventSelect_entry(dword_t caller,
                                           dword_t socket_handle,
                                           dword_t event_handle,
                                           dword_t network_events) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  object_ref<XEvent> ev;
  if (event_handle) {
    ev = kernel_state()->object_table()->LookupObject<XEvent>(event_handle);
    if (!ev) {
      XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
      return -1;
    }
  }

  int ret = socket->WSAEventSelect(std::move(ev), network_events);
  if (ret < 0) {
    XThread::SetLastError(socket->GetLastWSAError());
  }
  return ret;
}
DECLARE_XAM_EXPORT1(NetDll_WSAEventSelect, kNetworking, kImplemented);

dword_result_t NetDll___WSAFDIsSet_entry(dword_t socket_handle,
                                         pointer_t<x_fd_set> fd_set) {
  const uint8_t max_fd_count =
      std::min((uint32_t)fd_set->fd_count, uint32_t(64));
  for (uint8_t i = 0; i < max_fd_count; i++) {
    if (fd_set->fd_array[i] == socket_handle) {
      return 1;
    }
  }
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll___WSAFDIsSet, kNetworking, kImplemented);

void NetDll_WSASetLastError_entry(dword_t error_code) {
  XThread::SetLastError(error_code);
}
DECLARE_XAM_EXPORT1(NetDll_WSASetLastError, kNetworking, kImplemented);

dword_result_t NetDll_getsockname_entry(dword_t caller, dword_t socket_handle,
                                        lpvoid_t buf_ptr, lpdword_t len_ptr) {
  auto socket =
      kernel_state()->object_table()->LookupObject<XSocket>(socket_handle);
  if (!socket) {
    XThread::SetLastError(uint32_t(X_WSAError::X_WSAENOTSOCK));
    return -1;
  }

  int buffer_len = *len_ptr;

  X_STATUS status = socket->GetSockName(buf_ptr, &buffer_len);
  if (XFAILED(status)) {
    XThread::SetLastError(socket->GetLastWSAError());
    return -1;
  }

  *len_ptr = buffer_len;
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_getsockname, kNetworking, kImplemented);

// The top byte of an XNKID is its session class. Only these three are valid;
// upstream's IsValidXNKID rejects anything else outright.
// docs/netplay-port/xnet.h.ported.
constexpr uint8_t XNKID_SYSTEM_LINK = 0x00;
constexpr uint8_t XNKID_ONLINE = 0xAE;
constexpr uint8_t XNKID_SERVER = 0xC0;

dword_result_t NetDll_XNetCreateKey_entry(dword_t caller, lpdword_t key_id,
                                          lpdword_t exchange_key) {
  // *** THIS USED TO Fill() BOTH BUFFERS WITH 0xBE. *** Two things wrong with
  // that, both measured on two consoles during a System Link join:
  //
  //   - 0xBE is not one of the three session classes above, so the session id
  //     failed IsValidXNKID. Halo 3 completed the whole peer exchange - probe
  //     out, 12-byte answer back - and then called XNetUnregisterKey and gave
  //     up, which is the shape of a title rejecting the key rather than
  //     failing to reach anyone.
  //   - It is a CONSTANT. Every console produced session id
  //     BEBEBEBEBEBEBEBE, so no two sessions on a LAN were distinguishable -
  //     the same class of bug as the all-zero MAC in 4f47801be.
  //
  // Generated the way upstream's GenerateSessionId does: the class in the top
  // byte, 48 random bits below it, stored big-endian as the guest expects.
  static std::mt19937_64 rng(std::random_device{}());
  std::uniform_int_distribution<uint64_t> dist;

  const uint64_t session_id = (uint64_t(XNKID_SYSTEM_LINK) << 56) |
                              (dist(rng) & 0x0000FFFFFFFFFFFFull);

  const xe::be<uint64_t> be_session_id = session_id;
  std::memcpy(kernel_memory()->TranslateVirtual<uint8_t*>(
                  key_id.guest_address()),
              &be_session_id, sizeof(be_session_id));

  // XNKEY is 16 opaque bytes. Nothing on a LAN verifies it, but it has to
  // differ per session or two hosts hand out the same exchange key.
  auto* key = kernel_memory()->TranslateVirtual<uint8_t*>(
      exchange_key.guest_address());
  for (size_t i = 0; i < 16; i += 8) {
    const uint64_t chunk = dist(rng);
    std::memcpy(key + i, &chunk, sizeof(chunk));
  }

  XELOGI("XNetCreateKey: session id {:016X}", session_id);
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetCreateKey, kNetworking, kStub);

dword_result_t NetDll_XNetRegisterKey_entry(dword_t caller, lpdword_t key_id,
                                            lpdword_t exchange_key) {
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetRegisterKey, kNetworking, kStub);

dword_result_t NetDll_XNetUnregisterKey_entry(dword_t caller,
                                              lpdword_t key_id) {
  return 0;
}
DECLARE_XAM_EXPORT1(NetDll_XNetUnregisterKey, kNetworking, kStub);

}  // namespace xam
}  // namespace kernel
}  // namespace xe

DECLARE_XAM_EMPTY_REGISTER_EXPORTS(Net);
