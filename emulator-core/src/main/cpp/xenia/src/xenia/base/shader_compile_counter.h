#ifndef XENIA_BASE_SHADER_COMPILE_COUNTER_H_
#define XENIA_BASE_SHADER_COMPILE_COUNTER_H_
#include <atomic>
#include <chrono>
#include <cstdint>
namespace xe {
// Number of GPU pipelines/shaders currently being created (in-flight).
// Today this is 0 or 1 (synchronous creation on the command-processor thread);
// it becomes >1 once async pipeline creation lands. Always-on, trivially cheap.
inline std::atomic<uint32_t>& shader_compiles_in_flight() {
  static std::atomic<uint32_t> counter{0};
  return counter;
}
inline uint32_t shader_compiles_in_flight_count() {
  return shader_compiles_in_flight().load(std::memory_order_relaxed);
}
// Pipeline creations so far and the time spent in them (a driver compile or a
// pipeline cache hit), for run summaries. Only grow; readers take deltas.
inline std::atomic<uint64_t>& shader_compiles_total() {
  static std::atomic<uint64_t> counter{0};
  return counter;
}
inline std::atomic<uint64_t>& shader_compile_ns_total() {
  static std::atomic<uint64_t> counter{0};
  return counter;
}
// RAII guard: increment on construction, decrement on destruction. Use around
// each pipeline/shader create so it survives early returns. Two clock reads per
// creation, which itself takes from microseconds (cache hit) to many milliseconds.
class ScopedShaderCompile {
 public:
  ScopedShaderCompile() : start_(std::chrono::steady_clock::now()) {
    shader_compiles_in_flight().fetch_add(1, std::memory_order_relaxed);
  }
  ~ScopedShaderCompile() {
    shader_compiles_in_flight().fetch_sub(1, std::memory_order_relaxed);
    shader_compiles_total().fetch_add(1, std::memory_order_relaxed);
    shader_compile_ns_total().fetch_add(
        uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
                     std::chrono::steady_clock::now() - start_)
                     .count()),
        std::memory_order_relaxed);
  }
  ScopedShaderCompile(const ScopedShaderCompile&) = delete;
  ScopedShaderCompile& operator=(const ScopedShaderCompile&) = delete;

 private:
  std::chrono::steady_clock::time_point start_;
};
}  // namespace xe
#endif  // XENIA_BASE_SHADER_COMPILE_COUNTER_H_
