/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2021 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/kernel/xam/apps/xlivebase_app.h"

#include "xenia/base/logging.h"

#include <asio.hpp>

struct XONLINE_SERVICE_INFO {
  xe::be<uint32_t> id;
  in_addr ip;
  xe::be<uint16_t> port;
  xe::be<uint16_t> reserved;
};

// Argument to XUserMuteListQuery. Layout from AdrianCassar/xenia-canary
// netplay_canary_experimental, xnet.h.
struct X_MUTE_SET_STATE {
  xe::be<uint32_t> user_index;
  xe::be<uint64_t> remote_xuid;
  xe::be<uint32_t> set_muted;
};
static_assert_size(X_MUTE_SET_STATE, 0x18);

namespace xe {
namespace kernel {
namespace xam {
namespace apps {

XLiveBaseApp::XLiveBaseApp(KernelState* kernel_state)
    : App(kernel_state, 0xFC) {}

// http://mb.mirage.org/bugzilla/xliveless/main.c

X_HRESULT XLiveBaseApp::DispatchMessageSync(uint32_t message,
                                            uint32_t buffer_ptr,
                                            uint32_t buffer_length) {
  // NOTE: buffer_length may be zero or valid.
  auto buffer = memory_->TranslateVirtual(buffer_ptr);
  // XENRA: same reason as the XGI entry log - presence, invites and XStorage
  // land here, and this build implements a fraction of what the PC netplay one
  // does, so a triage run needs to see which of them a title asks for.
  XELOGI("XLiveBase: msg={:08X}, buffer={:08X}, len={}", message, buffer_ptr,
         buffer_length);
  switch (message) {
    case 0x0005008C: {
      // Called on startup of blades dashboard v1888 to v2858
      XELOGD("XLiveBaseUnk5008C, unimplemented");
      return X_E_FAIL;
    }
    case 0x00050094: {
      // Called on startup of blades dashboard v4532 to v4552
      XELOGD("XLiveBaseUnk50094, unimplemented");
      return X_E_FAIL;
    }
    case 0x00058003: {
      /* Notes:
         - Called on startup of dashboard (netplay build)
         - used by other internet funtions to check if online (e.g.
         XamGetLiveHiveValueA)
         - Return is Saved elsewhere and used here
      */
      // XENRA (360 netplay): report the console as logged on when a LIVE
      // enabled profile is signed in.
      //
      // This used to hard-return DISCONNECTED, which is why every title
      // considered itself offline no matter what else worked. Titles cache
      // this and gate their online menus on it.
      //
      // *** IT IS NOT A CLAIM THAT MATCHES WORK. *** XSessionCreate and its
      // neighbours are still stubs, so a title will get past sign-in and then
      // fail when it actually tries to host or join. That is deliberate
      // sequencing - sign-in has to work before anything downstream of it can
      // be built or tested - not an oversight. Do not put "online play" in
      // release notes on the strength of this returning S_OK.
      const auto profile =
          kernel_state_->xam_state()->GetUserProfile(uint32_t(0));
      if (profile && profile->IsLiveEnabled()) {
        XELOGD("XLiveBaseLogonGetHR -> logged on");
        return X_E_SUCCESS;
      }
      XELOGD("XLiveBaseLogonGetHR -> disconnected (no LIVE enabled profile)");
      return 0x001510F1;  // X_ONLINE_S_LOGON_DISCONNECTED
    }
    case 0x00058004: {
      /* Notes:
         - Called on startup, seems to just return a bool in the buffer.
         - It is Saved elsewhere and used here
      */
      assert_true(!buffer_length || buffer_length == 4);
      XELOGD("XLiveBaseGetLogonId({:08X})", buffer_ptr);
      xe::store_and_swap<uint32_t>(buffer, 1);  // ?
      return X_E_SUCCESS;
    }
    case 0x00058006: {
      assert_true(!buffer_length || buffer_length == 4);
      XELOGD("XLiveBaseGetNatType({:08X})", buffer_ptr);
      // XENRA (360 netplay): titles read this straight after logon and treat a
      // failure as "not online", undoing the sign-in above. Reported as OPEN
      // because UPnP port mapping is what backs hosting here and it is verified
      // working on this network - see upnp.cc and the Netplay screen's network
      // check. A title that cannot host will find out from the session layer,
      // not from this.
      //
      // This used to write ONLY when buffer_length == 4. MEASURED on two
      // consoles, 2026-08-17, at log_level 3: Halo 3 calls this through
      // XMsgInProcessCall with buffer_length = 0 and a valid buffer_ptr, so the
      // guard skipped the store and the title read back whatever was already on
      // its stack. The note at the top of this function already says
      // buffer_length may be zero or valid, so key the store on the POINTER,
      // which is what the title actually hands us.
      //
      // *** THIS IS NOT THE SYSTEM LINK JOIN BLOCKER. I PREDICTED IT WAS AND
      // THE A/B SAID NO. *** The call sits right on the decision: the host
      // makes it once on receiving the 20-byte join request, the client makes
      // it TWICE on receiving the host's 12-byte answer - once per NAT being
      // compared - and the client then tears the join down with
      // XNetQosListen(RELEASE) + XNetUnregisterKey. The on-screen error is
      // about NAT compatibility. All of that fit, and it was still wrong:
      // MEASURED with this fixed, both consoles on the same build, the join
      // fails identically. Adjacency to the decision is not causation. Rule 76
      // again - that is three hypotheses from reading code, three misses.
      //
      // Kept because writing the value the title asked for is correct on its
      // own terms, not because it fixes anything. Do not cite it as a netplay
      // fix.
      if (buffer_ptr && (!buffer_length || buffer_length == 4)) {
        xe::store_and_swap<uint32_t>(buffer, 1);  // XONLINE_NAT_OPEN
      }
      return X_E_SUCCESS;
    }
    case 0x00058007: {
      // Occurs if title calls XOnlineGetServiceInfo, expects dwServiceId
      // and pServiceInfo. pServiceInfo should contain pointer to
      // XONLINE_SERVICE_INFO structure.
      XELOGD("XLiveBaseOnlineGetServiceInfo({:08X}, {:08X})", buffer_ptr,
             buffer_length);
      return 0x80151802;  // X_ONLINE_E_LOGON_NOT_LOGGED_ON
    }
    case 0x00058020: {
      // 0x00058004 is called right before this.
      // We should create a XamEnumerate-able empty list here, but I'm not
      // sure of the format.
      // buffer_length seems to be the same ptr sent to 0x00058004.
      XELOGD("CXLiveFriends::Enumerate({:08X}, {:08X}) unimplemented",
             buffer_ptr, buffer_length);
      return X_E_FAIL;
    }
    case 0x0005800E: {
      XELOGD("XUserMuteListQuery({:08X}, {:08X})", buffer_ptr, buffer_length);
      // buffer_length is NOT a length here - it is the guest pointer the
      // result is written to. Measured: buffer=701EF0A0 "len"=701EF110, and
      // upstream reads it the same way.
      return XUserMuteListQuery(buffer_ptr, buffer_length);
    }
    case 0x00058023: {
      XELOGD(
          "CXLiveMessaging::XMessageGameInviteGetAcceptedInfo({:08X}, {:08X}) "
          "unimplemented",
          buffer_ptr, buffer_length);
      return X_E_FAIL;
    }
    case 0x00058037: {
      XELOGD("XPresenceInitialize({:08X}, {:08X})", buffer_ptr, buffer_length);
      return X_E_SUCCESS;
    }
    case 0x00058046: {
      // Required to be successful for 4D530910 to detect signed-in profile
      // Doesn't seem to set anything in the given buffer, probably only takes
      // input
      XELOGD("XLiveBaseUnk58046({:08X}, {:08X}) unimplemented", buffer_ptr,
             buffer_length);
      return X_E_SUCCESS;
    }
    case 0x00058017: {
      XELOGD("UserFindUsers({:08X}, {:08X})", buffer_ptr, buffer_length);
      return X_E_SUCCESS;
    }
    case 0x00058035: {
      // Fixes Xbox Live error for 513107D9
      // Required for 534507D4
      XELOGD("XLiveBaseUnk58035({:08X}, {:08X}) unimplemented", buffer_ptr,
             buffer_length);
      return X_E_SUCCESS;
    }
    case 0x00050036: {
      XELOGD("XOnlineQuerySearch({:08X}, {:08X}) unimplemented", buffer_ptr,
             buffer_length);
      return X_E_SUCCESS;
    }
    case 0x00050009: {
      // Fixes Xbox Live error for 513107D9
      XELOGD("XLiveBaseUnk50009({:08X}, {:08X}) unimplemented", buffer_ptr,
             buffer_length);
      return X_E_SUCCESS;
    }
  }
  XELOGE(
      "Unimplemented XLIVEBASE message app={:08X}, msg={:08X}, arg1={:08X}, "
      "arg2={:08X}",
      app_id(), message, buffer_ptr, buffer_length);
  return X_E_FAIL;
}

/*
 * "Is this remote player on my mute list?" - asked once per remote player as a
 * System Link lobby forms.
 *
 * MEASURED 2026-08-22, DiRT 3, two devices: the host called this 529 times in
 * a parked poll loop and got X_E_FAIL every time, while the joining console -
 * which had already found the session, resolved the host's XNADDR and opened a
 * TCP connection to it - gave up six frames later, unregistered its session
 * keys and closed every socket. The PC netplay build implements this; that
 * makes it one of only two XLiveBase differences that fire during a join.
 *
 * Upstream answers from a friends_manager backed by the Xbox Live services
 * this build has no client for. It does not need one: a System Link lobby has
 * no friends list and no mute list, so the true answer here is always "not
 * muted". Writing that is the whole implementation - and unlike returning
 * X_E_FAIL, it is an answer the guest can proceed from.
 *
 * Deliberately more permissive than upstream in one place: upstream rejects a
 * remote XUID that is not an online XUID with X_E_INVALIDARG, and System Link
 * peers are exactly the players who may not have one. Rejecting them would put
 * the caller back in the same loop for a different reason.
 */
X_HRESULT XLiveBaseApp::XUserMuteListQuery(uint32_t buffer_ptr,
                                           uint32_t mute_state_ptr) {
  if (!buffer_ptr || !mute_state_ptr) {
    return X_E_INVALIDARG;
  }

  const auto* request =
      memory_->TranslateVirtual<const X_MUTE_SET_STATE*>(buffer_ptr);
  if (request->user_index >= XUserMaxUserCount) {
    return X_E_INVALIDARG;
  }

  auto* muted = memory_->TranslateVirtual<xe::be<uint32_t>*>(mute_state_ptr);
  *muted = 0;

  return X_E_SUCCESS;
}

}  // namespace apps
}  // namespace xam
}  // namespace kernel
}  // namespace xe
