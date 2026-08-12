// JNI bridge for the 360 netplay UPnP layer.
//
// Exists so the port-mapping code can be exercised from the frontend, on a
// real device and a real router, without booting a title first - "it compiles"
// is not evidence that a router answers.
//
// Named by JNI's standard mangling rather than registered with
// RegisterNatives, which is deliberate: a class that DECLARES native methods
// is already covered by the app's `-keepclasseswithmembers class * { native
// <methods>; }` rule, so it cannot be renamed out from under this file. A
// class only ever reached by FindClass would have needed its own keep rule.
// See proguard-rules.pro.

#include <jni.h>

#include <string>

#include "xenia/kernel/upnp.h"
#include "xenia/kernel/util/network_adapter_manager.h"

namespace {

// One gateway per process. Discovery is slow and its result is a property of
// the network, not of the caller.
xe::kernel::UPnP& upnp() {
  static xe::kernel::UPnP instance;
  return instance;
}

jstring to_jstring(JNIEnv* env, const std::string& value) {
  return env->NewStringUTF(value.c_str());
}

}  // namespace

extern "C" {

// Returns the UPnPStatus ordinal, so the caller can tell "no gateway" from
// "gateway present but behind carrier NAT" - the two need different advice.
JNIEXPORT jint JNICALL
Java_xendroid_compose_UPnPCheck_nativeDiscover(JNIEnv* env, jclass clazz,
                                               jint timeout_ms) {
  upnp().Discover(static_cast<int>(timeout_ms));
  return static_cast<jint>(upnp().status());
}

JNIEXPORT jstring JNICALL
Java_xendroid_compose_UPnPCheck_nativeExternalAddress(JNIEnv* env,
                                                      jclass clazz) {
  return to_jstring(env, upnp().external_address());
}

JNIEXPORT jstring JNICALL
Java_xendroid_compose_UPnPCheck_nativeLanAddress(JNIEnv* env, jclass clazz) {
  return to_jstring(env, upnp().lan_address());
}

// Maps then immediately unmaps a port, purely to prove the gateway accepts a
// mapping from THIS process. Returns true only if the add succeeded.
//
// It cleans up after itself because leaving a mapping behind is a hole in
// somebody's router that outlives the app.
JNIEXPORT jboolean JNICALL
Java_xendroid_compose_UPnPCheck_nativeTestMapping(JNIEnv* env, jclass clazz,
                                                  jint port) {
  const auto value = static_cast<uint16_t>(port);
  if (!upnp().AddPortMapping(value, true, "Xenra netplay check")) {
    return JNI_FALSE;
  }
  upnp().DeletePortMapping(value, true);
  return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_xendroid_compose_UPnPCheck_nativeShutdown(JNIEnv* env, jclass clazz) {
  upnp().Shutdown();
}

/*!
 * Which interface netplay would present to the guest, as
 * "name|ip|wanRouting|allNames".
 *
 * Exists so the adapter picker is checked against a real device rather than
 * assumed: on a phone it must land on Wi-Fi and not on cellular, and "it
 * compiles" says nothing about which one getifaddrs happened to list first.
 * Packed as one delimited string rather than an object to avoid a second class
 * for a diagnostic.
 */
JNIEXPORT jstring JNICALL
Java_xendroid_compose_UPnPCheck_nativeAdapterSummary(JNIEnv* env, jclass clazz) {
  static xe::kernel::NetworkAdapterManager manager;
  manager.Initialize();

  std::string all;
  for (const auto& name : manager.GetAdaptersNames()) {
    if (!all.empty()) {
      all.push_back(',');
    }
    all.append(name);
  }

  const std::string summary =
      manager.GetSelectedAdapterName() + "|" +
      manager.GetSelectedAdapterLocalIPString() + "|" +
      (manager.IsSelectedAdapterWANRouting() ? "wan" : "nat") + "|" + all;

  return to_jstring(env, summary);
}

}  // extern "C"
