/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 */

#ifndef XENIA_BASE_FRAME_STATS_H_
#define XENIA_BASE_FRAME_STATS_H_

#include <atomic>
#include <chrono>
#include <cstdint>

namespace xe {

// Guest-frame present timing for the debug overlay.
//
// RecordGuestPresent() is called exactly once per presented GUEST frame (from
// the GPU command processor's IssueSwap), so the reported FPS / frame time
// reflect the actual game frame rate -- NOT the host UI repaint cadence (which
// keeps running at panel refresh even when the guest stalls). The producer is
// single-threaded (the command-processor thread); the published values are read
// from the UI thread via GetFrameStats(). A torn read across the three values
// is harmless for a debug readout.
namespace internal {
inline std::atomic<float>& frame_instant_ms() {
  static std::atomic<float> v{0.0f};
  return v;
}
inline std::atomic<float>& frame_avg_ms() {
  static std::atomic<float> v{0.0f};
  return v;
}
inline std::atomic<float>& frame_fps() {
  static std::atomic<float> v{0.0f};
  return v;
}
inline std::atomic<uint64_t>& guest_frame_index() {
  static std::atomic<uint64_t> v{0};
  return v;
}
// Frames per second reaching the DISPLAY, which is the guest rate until frame
// generation is on and higher after. Separate from frame_fps() on purpose: one
// is what the console produced and the other is what was shown, and collapsing
// them would hide exactly the thing frame generation does.
inline std::atomic<float>& host_present_fps() {
  static std::atomic<float> v{0.0f};
  return v;
}
// steady_clock nanoseconds of the last generated frame presented, or 0. Read as
// a recency test rather than a flag because generation stops on its own
// whenever the guest stops producing new images - on a pause, or a still menu -
// and a flag would have to be cleared from somewhere that knows that happened.
inline std::atomic<uint64_t>& last_generated_present_ns() {
  static std::atomic<uint64_t> v{0};
  return v;
}
}  // namespace internal

// Publishes the command processor's own frame counter - the SAME number the
// GPU logs stamp their lines with as "f:NNNNNNN".
//
// The point is joining the two halves of the evidence. Screenshots could show
// that a frame was wrong and the logs could show what the GPU did, but nothing
// tied a particular screenshot to a particular log line, so every conclusion
// had to be drawn from aggregates - which can exclude a hypothesis but can
// never identify one. With this on the debug overlay, a screenshot carries the
// exact frame it came from.
//
// Must be the command processor's counter and not a count of calls to
// RecordGuestPresent, or the numbers would drift apart and the join would
// silently line up the wrong frames.
inline void PublishGuestFrameIndex(uint64_t frame_index) {
  internal::guest_frame_index().store(frame_index, std::memory_order_relaxed);
}

inline uint64_t GetGuestFrameIndex() {
  return internal::guest_frame_index().load(std::memory_order_relaxed);
}

// Call once per presented guest frame (single producer thread).
// FPS is a RenderDoc-style average over a ~1s sliding time window (framerate
// independent); instant_ms stays the raw present-to-present delta.
inline void RecordGuestPresent() {
  using clock = std::chrono::steady_clock;
  static constexpr double kWindowMs = 1000.0;
  static constexpr size_t kCap = 1024;  // covers >1000 fps within the window
  static clock::time_point ts[kCap];
  static size_t head = 0;   // oldest sample
  static size_t count = 0;  // samples in the window
  static clock::time_point last{};

  clock::time_point now = clock::now();
  const bool have_last = last != clock::time_point{};
  double instant_ms =
      have_last ? std::chrono::duration<double, std::milli>(now - last).count()
                : 0.0;
  last = now;

  // A long gap (first frame / pause / load) restarts the window so the average
  // recovers within a second instead of being dragged by a stale outlier.
  if (!have_last || instant_ms > kWindowMs) {
    head = 0;
    count = 1;
    ts[0] = now;
    internal::frame_instant_ms().store(0.0f, std::memory_order_relaxed);
    internal::frame_avg_ms().store(0.0f, std::memory_order_relaxed);
    internal::frame_fps().store(0.0f, std::memory_order_relaxed);
    return;
  }

  const size_t tail = (head + count) % kCap;
  ts[tail] = now;
  if (count < kCap) {
    ++count;
  } else {
    head = (head + 1) % kCap;  // ring full: drop oldest
  }

  // Evict samples older than the window.
  while (count > 1 &&
         std::chrono::duration<double, std::milli>(now - ts[head]).count() >
             kWindowMs) {
    head = (head + 1) % kCap;
    --count;
  }

  const double span_ms =
      std::chrono::duration<double, std::milli>(now - ts[head]).count();
  const double fps =
      (count > 1 && span_ms > 0.0) ? double(count - 1) * 1000.0 / span_ms : 0.0;
  const double avg_ms = fps > 0.0 ? 1000.0 / fps : 0.0;

  internal::frame_instant_ms().store(float(instant_ms),
                                     std::memory_order_relaxed);
  internal::frame_avg_ms().store(float(avg_ms), std::memory_order_relaxed);
  internal::frame_fps().store(float(fps), std::memory_order_relaxed);
}

// Call once per present that actually reached the display, generated frames
// included (single producer thread - whichever one paints).
inline void RecordHostPresent(bool was_generated) {
  using clock = std::chrono::steady_clock;
  static constexpr double kWindowMs = 1000.0;
  static constexpr size_t kCap = 1024;
  static clock::time_point ts[kCap];
  static size_t head = 0;
  static size_t count = 0;
  static clock::time_point last{};

  const clock::time_point now = clock::now();
  if (was_generated) {
    internal::last_generated_present_ns().store(
        uint64_t(now.time_since_epoch().count()), std::memory_order_relaxed);
  }

  const bool have_last = last != clock::time_point{};
  const double instant_ms =
      have_last ? std::chrono::duration<double, std::milli>(now - last).count()
                : 0.0;
  last = now;

  // A long gap restarts the window, so the figure recovers within a second
  // rather than being dragged by a stale outlier.
  if (!have_last || instant_ms > kWindowMs) {
    head = 0;
    count = 1;
    ts[0] = now;
    internal::host_present_fps().store(0.0f, std::memory_order_relaxed);
    return;
  }

  const size_t tail = (head + count) % kCap;
  ts[tail] = now;
  if (count < kCap) {
    ++count;
  } else {
    head = (head + 1) % kCap;
  }
  while (count > 1 &&
         std::chrono::duration<double, std::milli>(now - ts[head]).count() >
             kWindowMs) {
    head = (head + 1) % kCap;
    --count;
  }

  const double span_ms =
      std::chrono::duration<double, std::milli>(now - ts[head]).count();
  const double fps =
      (count > 1 && span_ms > 0.0) ? double(count - 1) * 1000.0 / span_ms : 0.0;
  internal::host_present_fps().store(float(fps), std::memory_order_relaxed);
}

inline float GetHostPresentFps() {
  return internal::host_present_fps().load(std::memory_order_relaxed);
}

// Whether generated frames are reaching the display right now. True while one
// was presented within the last quarter second, which is long enough to ride
// out a slow frame and short enough that the readout follows a pause.
inline bool IsFrameGenerationActive() {
  const uint64_t last_ns =
      internal::last_generated_present_ns().load(std::memory_order_relaxed);
  if (!last_ns) {
    return false;
  }
  const uint64_t now_ns = uint64_t(
      std::chrono::steady_clock::now().time_since_epoch().count());
  return now_ns >= last_ns && (now_ns - last_ns) < 250000000ull;
}

// Read the latest published stats (any thread).
inline void GetFrameStats(float& instant_ms, float& avg_ms, float& fps) {
  instant_ms = internal::frame_instant_ms().load(std::memory_order_relaxed);
  avg_ms = internal::frame_avg_ms().load(std::memory_order_relaxed);
  fps = internal::frame_fps().load(std::memory_order_relaxed);
}

}  // namespace xe

#endif  // XENIA_BASE_FRAME_STATS_H_
