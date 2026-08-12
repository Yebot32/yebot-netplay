/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2026 Xenia Canary. All rights reserved.                          *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_KERNEL_HTTP_CLIENT_H_
#define XENIA_KERNEL_HTTP_CLIENT_H_

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace xe {
namespace kernel {

/*!
 * Blocking HTTPS transport for the netplay session broker.
 *
 * WHY THIS EXISTS INSTEAD OF libcurl. Upstream netplay's XLiveAPI talks to
 * Xenia-WebServices through libcurl, which on Android means vendoring curl AND
 * a TLS stack AND shipping a CA bundle we would then have to keep current.
 * Every one of those is a build risk and a maintenance burden for a single
 * feature. Android already has a hardened TLS stack and the system trust
 * store, so this interface is implemented by calling out to it over JNI - see
 * xe_http_jni.cpp. The price is that XLiveAPI's transport functions are
 * REWRITTEN against this header rather than ported verbatim; the rest of
 * XLiveAPI ports unchanged.
 *
 * DELIBERATELY MINIMAL. Enough verbs and enough of a response to carry the
 * broker's REST calls, and nothing more. No streaming, no redirects we do not
 * ask for, no connection reuse policy - if netplay ever needs any of that,
 * add it here rather than reaching around this header.
 *
 * THE IMPLEMENTATION LIVES OUTSIDE THE VENDORED TREE. Only this header sits
 * in the kernel; the Android implementation is in emulator-core's own cpp
 * directory beside the other xe_android_* platform code, and the symbol is
 * resolved when the static kernel library is linked into libe.so. A new file
 * here never conflicts with an upstream merge, and no Android detail leaks
 * into xenia's sources.
 */

//! Header name/value pairs, in the order they should be sent.
using HttpHeaders = std::vector<std::pair<std::string, std::string>>;

struct HttpResponse {
  /*!
   * Whether the exchange completed at the transport level - DNS, TCP, TLS and
   * a status line all the way back.
   *
   * Kept separate from the status code because the two demand different
   * handling: a 404 from the broker is an answer and the caller should read
   * it, while "the network is gone" is not an answer at any status. Upstream
   * conflates them behind a zero status and every caller has to remember that.
   */
  bool transport_ok = false;

  //! HTTP status. Zero when transport_ok is false, i.e. no status was reached.
  int status_code = 0;

  //! Response body. May legitimately be empty on a 204 or a HEAD-like call.
  std::string body;

  //! Human-readable transport failure. Empty when transport_ok is true.
  std::string error;

  //! The one check most callers want: we got there AND the server was happy.
  bool ok() const {
    return transport_ok && status_code >= 200 && status_code < 300;
  }
};

/*!
 * Whether the transport is usable at all.
 *
 * False before the Java side has been initialised (see XeHttp.ensureReady) or
 * on a build with no JNI host. Worth checking once at netplay start-up so the
 * failure reads as "netplay is not wired up" rather than as a network outage
 * on every request.
 */
bool HttpAvailable();

/*!
 * Perform one request and block until it completes or times out.
 *
 * SAFE FROM ANY THREAD, including guest dispatch threads the JVM has never
 * seen - the implementation attaches and detaches around the call. It is NOT
 * safe from Android's main thread, which will refuse network I/O outright;
 * that is a caller bug and comes back as transport_ok = false rather than as
 * a crash.
 *
 * \param method  HTTP verb, uppercase. GET/POST/PUT/DELETE.
 * \param url     Absolute URL. HTTPS strongly preferred; the app forbids
 *                cleartext traffic, so http:// will fail at the transport.
 * \param headers Extra request headers. Content-Type is NOT implied - set it.
 * \param body    Request body, sent verbatim. Ignored for GET and DELETE.
 * \param timeout_ms  Applied to connect and to read separately, so the true
 *                    ceiling is roughly twice this.
 */
HttpResponse HttpRequest(std::string_view method, std::string_view url,
                         const HttpHeaders& headers, std::string_view body,
                         int timeout_ms = 10000);

HttpResponse HttpGet(std::string_view url, const HttpHeaders& headers = {},
                     int timeout_ms = 10000);
HttpResponse HttpPost(std::string_view url, std::string_view body,
                      const HttpHeaders& headers = {}, int timeout_ms = 10000);
HttpResponse HttpDelete(std::string_view url, const HttpHeaders& headers = {},
                        int timeout_ms = 10000);

}  // namespace kernel
}  // namespace xe

#endif  // XENIA_KERNEL_HTTP_CLIENT_H_
