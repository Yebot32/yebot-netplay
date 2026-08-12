// The Android implementation of xe::kernel::HttpRequest - the HTTPS transport
// 360 netplay's session broker calls run over.
//
// The interface is declared in the kernel (xenia/src/xenia/kernel/
// http_client.h) and implemented HERE, outside the vendored tree, for the same
// reason upnp.cc is wired from emulator-core's CMakeLists rather than xenia's:
// a new file never conflicts on an upstream merge, and no Android detail ends
// up in xenia's sources. The symbol resolves when xenia-kernel is linked into
// libe.so.
//
// WHY NOT libcurl, which is what upstream netplay uses: it would mean
// vendoring curl, a TLS stack, and a CA bundle to keep current, for one
// feature. Android already has all three. See the header for the full note.

#include <jni.h>

#include <android/log.h>

#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "xenia/kernel/http_client.h"

#define XE_HTTP_LOG(level, ...) \
  __android_log_print(level, "XeHttpJni", __VA_ARGS__)

// Set in JNI_OnLoad (xendroid.cpp), which is the only place a JavaVM is handed
// to us. Same extern the emulator thread uses.
extern JavaVM* g_jvm;

namespace {

// Cached during XeHttp.nativeInit, which runs on a Java thread.
//
// THIS CACHE IS THE WHOLE POINT OF HAVING AN INIT CALL. FindClass on a thread
// we attached ourselves resolves against the SYSTEM class loader, which cannot
// see app classes - so looking XeHttp up lazily from a guest dispatch thread
// fails, and fails only there. Resolving both classes while a Java thread is
// on the stack and holding global references sidesteps it entirely.
jclass g_class_xe_http = nullptr;
jmethodID g_method_request = nullptr;
jclass g_class_result = nullptr;
jfieldID g_field_status = nullptr;
jfieldID g_field_body = nullptr;
jfieldID g_field_error = nullptr;
bool g_ready = false;

/*!
 * A JNIEnv for the current thread, whatever kind of thread it is.
 *
 * Detaches on destruction ONLY if it was the one that attached, so this can
 * never pull an env out from under a Java thread further up the stack. Netplay
 * requests are infrequent enough that per-call attach costs nothing worth
 * optimising, and leaving guest threads permanently attached would pin JVM
 * thread state to threads the JVM has no other reason to know about.
 */
class ScopedEnv {
 public:
  ScopedEnv() {
    if (!g_jvm) {
      return;
    }
    const jint status = g_jvm->GetEnv(reinterpret_cast<void**>(&env_),
                                      JNI_VERSION_1_6);
    if (status == JNI_OK) {
      return;
    }
    if (status == JNI_EDETACHED &&
        g_jvm->AttachCurrentThread(&env_, nullptr) == JNI_OK) {
      attached_ = true;
      return;
    }
    env_ = nullptr;
  }

  ~ScopedEnv() {
    if (attached_) {
      g_jvm->DetachCurrentThread();
    }
  }

  ScopedEnv(const ScopedEnv&) = delete;
  ScopedEnv& operator=(const ScopedEnv&) = delete;

  JNIEnv* get() const { return env_; }
  explicit operator bool() const { return env_ != nullptr; }

 private:
  JNIEnv* env_ = nullptr;
  bool attached_ = false;
};

std::string to_string(JNIEnv* env, jstring value) {
  if (!value) {
    return {};
  }
  const char* chars = env->GetStringUTFChars(value, nullptr);
  std::string out = chars ? chars : "";
  if (chars) {
    env->ReleaseStringUTFChars(value, chars);
  }
  return out;
}

//! Pack headers the way XeHttp.request unpacks them: `Name: Value` per line.
std::string pack_headers(const xe::kernel::HttpHeaders& headers) {
  std::string out;
  for (const auto& [name, value] : headers) {
    if (name.empty()) {
      continue;
    }
    if (!out.empty()) {
      out.push_back('\n');
    }
    out.append(name).append(": ").append(value);
  }
  return out;
}

/*!
 * Turn a pending Java exception into a message and clear it.
 *
 * An exception left pending makes the next JNI call abort the process, so this
 * must run before anything else touches env. XeHttp.request catches Throwable
 * itself, so reaching here means something outside that catch went wrong -
 * OOM building the arguments, most likely.
 */
std::string take_exception(JNIEnv* env) {
  if (!env->ExceptionCheck()) {
    return {};
  }
  env->ExceptionDescribe();
  env->ExceptionClear();
  return "java exception during request";
}

}  // namespace

namespace xe {
namespace kernel {

bool HttpAvailable() { return g_ready; }

HttpResponse HttpRequest(std::string_view method, std::string_view url,
                         const HttpHeaders& headers, std::string_view body,
                         int timeout_ms) {
  HttpResponse response;

  if (!g_ready) {
    response.error = "http transport not initialised (XeHttp.ensureReady)";
    return response;
  }

  ScopedEnv scoped;
  if (!scoped) {
    response.error = "could not attach to the jvm";
    return response;
  }
  JNIEnv* env = scoped.get();

  // One frame for every local reference below, so nothing leaks on an early
  // return and none of this depends on the caller's frame having room.
  if (env->PushLocalFrame(16) != JNI_OK) {
    response.error = "out of jni local references";
    return response;
  }

  const std::string method_str(method);
  const std::string url_str(url);
  const std::string headers_str = pack_headers(headers);

  jstring j_method = env->NewStringUTF(method_str.c_str());
  jstring j_url = env->NewStringUTF(url_str.c_str());
  jstring j_headers = env->NewStringUTF(headers_str.c_str());

  jbyteArray j_body = nullptr;
  if (!body.empty()) {
    j_body = env->NewByteArray(static_cast<jsize>(body.size()));
    if (j_body) {
      env->SetByteArrayRegion(
          j_body, 0, static_cast<jsize>(body.size()),
          reinterpret_cast<const jbyte*>(body.data()));
    }
  }

  if (!j_method || !j_url || !j_headers) {
    env->ExceptionClear();
    env->PopLocalFrame(nullptr);
    response.error = "out of memory building the request";
    return response;
  }

  jobject result = env->CallStaticObjectMethod(
      g_class_xe_http, g_method_request, j_method, j_url, j_headers, j_body,
      static_cast<jint>(timeout_ms));

  std::string failure = take_exception(env);
  if (!failure.empty() || !result) {
    env->PopLocalFrame(nullptr);
    response.error = failure.empty() ? "request returned nothing" : failure;
    return response;
  }

  jstring j_error =
      static_cast<jstring>(env->GetObjectField(result, g_field_error));
  if (j_error) {
    response.error = to_string(env, j_error);
    env->PopLocalFrame(nullptr);
    return response;
  }

  // No error field means the exchange completed, whatever the server thought
  // of it. That is what transport_ok records, and why it is not derived from
  // the status code.
  response.transport_ok = true;
  response.status_code =
      static_cast<int>(env->GetIntField(result, g_field_status));

  jbyteArray j_response_body =
      static_cast<jbyteArray>(env->GetObjectField(result, g_field_body));
  if (j_response_body) {
    const jsize length = env->GetArrayLength(j_response_body);
    response.body.resize(static_cast<size_t>(length));
    if (length > 0) {
      env->GetByteArrayRegion(j_response_body, 0, length,
                              reinterpret_cast<jbyte*>(response.body.data()));
    }
  }

  env->PopLocalFrame(nullptr);
  return response;
}

HttpResponse HttpGet(std::string_view url, const HttpHeaders& headers,
                     int timeout_ms) {
  return HttpRequest("GET", url, headers, {}, timeout_ms);
}

HttpResponse HttpPost(std::string_view url, std::string_view body,
                      const HttpHeaders& headers, int timeout_ms) {
  return HttpRequest("POST", url, headers, body, timeout_ms);
}

HttpResponse HttpDelete(std::string_view url, const HttpHeaders& headers,
                        int timeout_ms) {
  return HttpRequest("DELETE", url, headers, {}, timeout_ms);
}

}  // namespace kernel
}  // namespace xe

extern "C" {

JNIEXPORT void JNICALL
Java_xendroid_compose_XeHttp_nativeInit(JNIEnv* env, jclass clazz) {
  if (g_ready) {
    return;
  }

  // clazz is XeHttp itself, handed over by JNI - no lookup needed for it. The
  // Result lookup below is the one that has to happen HERE, on this thread.
  g_class_xe_http = static_cast<jclass>(env->NewGlobalRef(clazz));
  g_method_request = env->GetStaticMethodID(
      g_class_xe_http, "request",
      "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;[BI)"
      "Lxendroid/compose/XeHttp$Result;");

  jclass result_local = env->FindClass("xendroid/compose/XeHttp$Result");
  if (result_local) {
    g_class_result = static_cast<jclass>(env->NewGlobalRef(result_local));
    g_field_status = env->GetFieldID(g_class_result, "status", "I");
    g_field_body = env->GetFieldID(g_class_result, "body", "[B");
    g_field_error =
        env->GetFieldID(g_class_result, "error", "Ljava/lang/String;");
    env->DeleteLocalRef(result_local);
  }

  if (env->ExceptionCheck()) {
    env->ExceptionDescribe();
    env->ExceptionClear();
  }

  g_ready = g_method_request && g_class_result && g_field_status &&
            g_field_body && g_field_error;

  if (!g_ready) {
    // Almost certainly R8 having renamed or dropped request()/Result in a
    // release build. Say so, because the symptom otherwise is netplay quietly
    // failing every call in release and working in debug.
    XE_HTTP_LOG(ANDROID_LOG_ERROR,
                "transport init failed - is the XeHttp keep rule present?");
  } else {
    XE_HTTP_LOG(ANDROID_LOG_INFO, "transport ready");
  }
}

/*!
 * Runs one GET through the core's own path, from a thread the JVM has never
 * seen, and reports what came back.
 *
 * The std::thread is the point of the test, not an implementation detail:
 * calling HttpRequest straight from here would run on a Java thread that
 * already has an env, and would prove nothing about the attach path or the
 * cached class references - which is exactly where this design can fail, and
 * where it would fail only once a guest thread made the first real call.
 */
JNIEXPORT jint JNICALL
Java_xendroid_compose_XeHttp_nativeSelfTest(JNIEnv* env, jclass clazz,
                                            jstring url, jint timeout_ms) {
  // Mirrors XeHttp.SELFTEST_*.
  constexpr jint kTransportFailed = -1;
  constexpr jint kNotReady = -2;

  if (!g_ready) {
    XE_HTTP_LOG(ANDROID_LOG_ERROR, "self test: transport not initialised");
    return kNotReady;
  }

  const std::string target = to_string(env, url);

  xe::kernel::HttpResponse response;
  std::thread worker([&]() {
    response = xe::kernel::HttpGet(target, {{"Accept", "*/*"}},
                                   static_cast<int>(timeout_ms));
  });
  worker.join();

  if (!response.transport_ok) {
    XE_HTTP_LOG(ANDROID_LOG_WARN, "self test: %s -> transport failed: %s",
                target.c_str(), response.error.c_str());
    return kTransportFailed;
  }

  XE_HTTP_LOG(ANDROID_LOG_INFO, "self test: %s -> HTTP %d, %zu bytes",
              target.c_str(), response.status_code, response.body.size());
  return static_cast<jint>(response.status_code);
}

}  // extern "C"
