#include "XenraAudio.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

#include "xenia/apu/audio_driver.h"
#include "xenia/apu/conversion.h"
#include "xenia/base/logging.h"
#include "xenia/base/threading.h"

namespace {

using xe::X_STATUS;
using xe::apu::AudioDriver;

// Each buffer carries a few guest frames: an AudioQueue is not built for
// buffers of 5 ms, the length of one.
constexpr uint32_t kBufferCount = 4;
constexpr uint32_t kFramesPerBuffer = 4;

// Note on queue depth: frames_ needs no cap of its own. The producer only
// submits against the client semaphore, which Fill releases one per frame
// played, so the depth is already bounded by apu_max_queued_frames, and the
// worker deliberately tops it up to half of that. Dropping frames here would
// fight that rate control and underrun.

class QueueDriver;

// Every live driver, so an audio interruption (a call, Siri, an alarm) can
// restart them all when it ends: iOS stops the queues and does not restart
// them itself, and the guest would play silence until the next boot.
std::mutex& DriversMutex() {
  static std::mutex mutex;
  return mutex;
}
std::vector<QueueDriver*>& Drivers() {
  static std::vector<QueueDriver*> drivers;
  return drivers;
}

class QueueDriver final : public AudioDriver {
 public:
  QueueDriver(xe::threading::Semaphore* semaphore, uint32_t frequency,
              uint32_t channels, bool need_format_conversion)
      : semaphore_(semaphore),
        frequency_(frequency),
        guest_channels_(channels),
        need_format_conversion_(need_format_conversion),
        // The media player submits kFrameSamplesMax floats whatever the count.
        channel_samples_(kFrameSamplesMax / channels),
        // 5.1 goes down to stereo here; tablets have nothing else to play it on.
        out_channels_(channels == 6 && need_format_conversion ? 2 : channels) {
    std::lock_guard<std::mutex> lock(DriversMutex());
    Drivers().push_back(this);
  }
  ~QueueDriver() override {
    {
      std::lock_guard<std::mutex> lock(DriversMutex());
      auto& drivers = Drivers();
      drivers.erase(std::remove(drivers.begin(), drivers.end(), this),
                    drivers.end());
    }
    Shutdown();
  }

  // After an interruption ends: start again, unless the core paused us.
  void Recover() {
    if (queue_ && !paused_.load()) {
      OSStatus status = AudioQueueStart(queue_, nullptr);
      if (status != noErr) {
        XELOGW("iOS audio: restart after interruption failed: {}", int(status));
      }
    }
  }

  bool Initialize() override {
    AudioStreamBasicDescription format = {};
    format.mSampleRate = frequency_;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = out_channels_;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = out_channels_ * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerPacket = format.mBytesPerFrame;
    OSStatus status =
        AudioQueueNewOutput(&format, Callback, this, nullptr, nullptr, 0, &queue_);
    if (status != noErr) {
      XELOGE("iOS audio: AudioQueueNewOutput failed: {}", int(status));
      return false;
    }
    const uint32_t bytes = kFramesPerBuffer * channel_samples_ *
                           out_channels_ * sizeof(float);
    for (uint32_t i = 0; i < kBufferCount; i++) {
      AudioQueueBufferRef buffer = nullptr;
      if (AudioQueueAllocateBuffer(queue_, bytes, &buffer) != noErr) {
        return false;
      }
      Fill(buffer);
      AudioQueueEnqueueBuffer(queue_, buffer, 0, nullptr);
    }
    return AudioQueueStart(queue_, nullptr) == noErr;
  }

  void Shutdown() override {
    if (queue_) {
      AudioQueueStop(queue_, true);
      AudioQueueDispose(queue_, true);
      queue_ = nullptr;
    }
  }

  void SubmitFrame(float* samples) override {
    const size_t count = guest_channels_ * channel_samples_;
    std::vector<float> frame(samples, samples + count);
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.push_back(std::move(frame));
  }

  void Pause() override {
    paused_ = true;
    if (queue_) AudioQueuePause(queue_);
  }
  void Resume() override {
    paused_ = false;
    if (queue_) AudioQueueStart(queue_, nullptr);
  }
  void SetVolume(float volume) override {
    if (queue_) AudioQueueSetParameter(queue_, kAudioQueueParam_Volume, volume);
  }
  size_t GetQueuedFrameCount() override {
    std::lock_guard<std::mutex> lock(mutex_);
    return frames_.size();
  }

 private:
  static void Callback(void* self, AudioQueueRef, AudioQueueBufferRef buffer) {
    auto* driver = static_cast<QueueDriver*>(self);
    driver->Fill(buffer);
    AudioQueueEnqueueBuffer(driver->queue_, buffer, 0, nullptr);
  }

  // Short of frames the rest is silence, and the producer catches up.
  void Fill(AudioQueueBufferRef buffer) {
    auto* out = static_cast<float*>(buffer->mAudioData);
    const uint32_t frame_samples = channel_samples_ * out_channels_;
    std::memset(out, 0, buffer->mAudioDataBytesCapacity);
    buffer->mAudioDataByteSize = buffer->mAudioDataBytesCapacity;
    for (uint32_t i = 0; i < kFramesPerBuffer; i++) {
      std::vector<float> frame;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        if (frames_.empty()) return;
        frame = std::move(frames_.front());
        frames_.pop_front();
      }
      float* target = out + i * frame_samples;
      if (out_channels_ != guest_channels_) {
        xe::apu::conversion::sequential_6_BE_to_interleaved_2_LE(
            target, frame.data(), channel_samples_);
      } else {
        std::memcpy(target, frame.data(), frame_samples * sizeof(float));
      }
      if (semaphore_) semaphore_->Release(1, nullptr);
    }
  }

  xe::threading::Semaphore* semaphore_;
  uint32_t frequency_;
  uint32_t guest_channels_;
  bool need_format_conversion_;
  uint32_t channel_samples_;
  uint32_t out_channels_;
  AudioQueueRef queue_ = nullptr;
  std::atomic<bool> paused_{false};
  std::mutex mutex_;
  std::deque<std::vector<float>> frames_;
};

class QueueAudioSystem final : public xe::apu::AudioSystem {
 public:
  explicit QueueAudioSystem(xe::cpu::Processor* processor)
      : AudioSystem(processor) {
    AVAudioSession* session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayback error:nil];
    [session setActive:YES error:nil];
    WatchInterruptions();
  }

  static void WatchInterruptions() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      [NSNotificationCenter.defaultCenter
          addObserverForName:AVAudioSessionInterruptionNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification* note) {
                    const auto type = AVAudioSessionInterruptionType(
                        [note.userInfo[AVAudioSessionInterruptionTypeKey]
                            unsignedIntegerValue]);
                    XELOGI("iOS audio: interruption {}",
                           type == AVAudioSessionInterruptionTypeBegan
                               ? "began"
                               : "ended");
                    if (type != AVAudioSessionInterruptionTypeEnded) return;
                    [AVAudioSession.sharedInstance setActive:YES error:nil];
                    std::lock_guard<std::mutex> lock(DriversMutex());
                    for (QueueDriver* driver : Drivers()) driver->Recover();
                  }];
    });
  }

  std::string name() const override { return "AudioQueue"; }

  X_STATUS CreateDriver(size_t index, xe::threading::Semaphore* semaphore,
                        AudioDriver** out_driver) override {
    auto driver = std::make_unique<QueueDriver>(
        semaphore, AudioDriver::kFrameFrequencyDefault,
        AudioDriver::kFrameChannelsDefault, true);
    if (!driver->Initialize()) {
      return X_STATUS_UNSUCCESSFUL;
    }
    *out_driver = driver.release();
    return X_STATUS_SUCCESS;
  }

  // The media player's: a song's own rate and format, not the guest mix.
  AudioDriver* CreateDriver(xe::threading::Semaphore* semaphore,
                            uint32_t frequency, uint32_t channels,
                            bool need_format_conversion) override {
    return new QueueDriver(semaphore, frequency, channels,
                           need_format_conversion);
  }

  void DestroyDriver(AudioDriver* driver) override { delete driver; }
};

}  // namespace

std::unique_ptr<xe::apu::AudioSystem> XenraCreateAudioSystem(
    xe::cpu::Processor* processor) {
  return std::make_unique<QueueAudioSystem>(processor);
}
