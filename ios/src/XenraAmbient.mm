#import "XenraAmbient.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

#import "XenraScreens.h"
#import "XenraSettings.h"

// Numbers and structure are AmbientMusic.kt's; the reasons are written there.
namespace {

constexpr int kSampleRate = 22050;
constexpr int kBlockFrames = 4096;
constexpr int kBuffers = 3;
constexpr double kChordSeconds = 8.0;
constexpr double kFadeSeconds = 2.2;
constexpr int kTableSize = 1 << 12;

struct Palette {
  int chords[4][4];
  float cutoff_base;
  float cutoff_depth;
  float voice_gains[4];
  float sub_gain;
  float detune;
  float pluck_gain;
  float pluck_period;
  float pluck_decay;
  float breath_depth;
  float pluck_tone;
};

constexpr Palette kPaletteXbox = {
    {{55, 60, 64, 67}, {53, 60, 65, 69}, {55, 62, 67, 71}, {57, 60, 64, 69}},
    0.60f, 0.06f, {0.18f, 0.14f, 0.10f, 0.07f}, 0.09f, 0.0008f,
    0.08f, 1.0f, 0.99968f, 0.02f, 0.18f,
};

constexpr Palette kPaletteX360 = {
    {{62, 67, 74, 79}, {60, 67, 72, 79}, {64, 69, 76, 81}, {62, 69, 74, 81}},
    0.72f, 0.05f, {0.15f, 0.12f, 0.09f, 0.07f}, 0.04f, 0.0010f,
    0.13f, 0.5f, 0.99974f, 0.02f, 0.40f,
};

float g_sine[kTableSize + 1];

float Sine(float phase) {
  float p = phase - int(phase);
  if (p < 0) p += 1;
  const float x = p * kTableSize;
  const int i = int(x);
  return g_sine[i] + (g_sine[i + 1] - g_sine[i]) * (x - i);
}

float MidiToInc(int note) {
  return float(440.0 * std::pow(2.0, (note - 69) / 12.0) / kSampleRate);
}

float Clamp(float value, float low, float high) {
  return std::min(std::max(value, low), high);
}

std::atomic<const Palette*> g_palette{&kPaletteXbox};
std::atomic<float> g_target_gain{0};
std::atomic<bool> g_stopping{false};
AudioQueueRef g_queue;
bool g_finishing;

struct Voice {
  float phase_l[8], phase_r[8];
  float sub_l = 0, sub_r = 0.5f;
  float lfo_slow = 0, lfo_mid = 0.25f;
  float lp_l = 0, lp_r = 0;
  float gain = 0;
  int64_t frame = 0;
  float cur_inc[4], next_inc[4];
  int chord = -1;
  const Palette* palette = &kPaletteXbox;
  float pluck_phase = 0, pluck_inc = 0, pluck_env = 0, pluck_pan = 0.5f;
  float pluck_timer = 0;
  int pluck_step = 0;
} g_voice;

void ResetVoice() {
  g_voice = Voice();
  for (int i = 0; i < 8; i++) {
    g_voice.phase_l[i] = i * 0.13f;
    g_voice.phase_r[i] = i * 0.19f + 0.5f;
  }
  g_voice.palette = g_palette.load();
}

void Render(int16_t* out) {
  Voice& s = g_voice;
  const float fade_step = 1.0f / float(kFadeSeconds * kSampleRate);
  s.lfo_slow += (0.031f / kSampleRate) * kBlockFrames;
  s.lfo_mid += (0.073f / kSampleRate) * kBlockFrames;
  const Palette* wanted = g_palette.load();
  if (wanted != s.palette) {
    s.palette = wanted;
    s.chord = -1;
  }
  const Palette& pal = *s.palette;
  const float breath =
      (1 - pal.breath_depth) + pal.breath_depth * Sine(s.lfo_slow);
  const float cutoff =
      pal.cutoff_base + pal.cutoff_depth * (0.5f + 0.5f * Sine(s.lfo_mid));

  for (int f = 0; f < kBlockFrames; f++) {
    const double position = double(s.frame) / kSampleRate / kChordSeconds;
    const int chord = int(position);
    const float frac = float(position - chord);
    if (chord != s.chord) {
      const bool first = s.chord < 0;
      s.chord = chord;
      if (!first) {
        for (int v = 0; v < 4; v++) {
          s.phase_l[v] = s.phase_l[v + 4];
          s.phase_r[v] = s.phase_r[v + 4];
        }
      }
      for (int v = 0; v < 4; v++) {
        s.cur_inc[v] = MidiToInc(pal.chords[chord % 4][v]);
        s.next_inc[v] = MidiToInc(pal.chords[(chord + 1) % 4][v]);
      }
    }

    const float xfade = frac > 0.75f ? (frac - 0.75f) / 0.25f : 0;
    const float w_cur = std::cos(xfade * float(M_PI) / 2);
    const float w_next = std::sin(xfade * float(M_PI) / 2);
    const bool blending = w_next > 0;
    float sum_l = 0, sum_r = 0;

    for (int v = 0; v < 4; v++) {
      const float detune = 1 + pal.detune * (v % 2 == 0 ? 1 : -1);
      s.phase_l[v] += s.cur_inc[v];
      s.phase_r[v] += s.cur_inc[v] * detune;
      const float voice_gain = pal.voice_gains[v];
      if (blending) {
        s.phase_l[v + 4] += s.next_inc[v];
        s.phase_r[v + 4] += s.next_inc[v] * detune;
        sum_l += (Sine(s.phase_l[v]) * w_cur + Sine(s.phase_l[v + 4]) * w_next) *
                 voice_gain;
        sum_r += (Sine(s.phase_r[v]) * w_cur + Sine(s.phase_r[v + 4]) * w_next) *
                 voice_gain;
      } else {
        sum_l += Sine(s.phase_l[v]) * voice_gain;
        sum_r += Sine(s.phase_r[v]) * voice_gain;
      }
      if (v == 0) {
        s.sub_l += s.cur_inc[0] * 0.5f;
        s.sub_r += s.cur_inc[0] * 0.5f * detune;
        sum_l += Sine(s.sub_l) * pal.sub_gain;
        sum_r += Sine(s.sub_r) * pal.sub_gain;
      }
    }

    s.pluck_timer -= 1.0f / kSampleRate;
    if (s.pluck_timer <= 0) {
      s.pluck_timer += pal.pluck_period;
      const int note = pal.chords[chord % 4][s.pluck_step % 4] + 12;
      s.pluck_inc = MidiToInc(note);
      s.pluck_phase = 0;
      s.pluck_env = 1;
      s.pluck_pan = s.pluck_step % 2 == 0 ? 0.34f : 0.66f;
      s.pluck_step++;
    }
    if (s.pluck_env > 0.0005f) {
      s.pluck_phase += s.pluck_inc;
      const float v =
          (Sine(s.pluck_phase) + pal.pluck_tone * Sine(s.pluck_phase * 2)) *
          s.pluck_env * pal.pluck_gain;
      sum_l += v * (1 - s.pluck_pan);
      sum_r += v * s.pluck_pan;
      s.pluck_env *= pal.pluck_decay;
    }

    s.lp_l += cutoff * (sum_l - s.lp_l);
    s.lp_r += cutoff * (sum_r - s.lp_r);
    const float sat_l = Clamp(s.lp_l * s.gain, -1, 1);
    const float sat_r = Clamp(s.lp_r * s.gain, -1, 1);
    const float warm_l = (sat_l - sat_l * sat_l * sat_l * 0.333f) * 1.5f;
    const float warm_r = (sat_r - sat_r * sat_r * sat_r * 0.333f) * 1.5f;

    const float want = g_stopping ? 0 : g_target_gain.load();
    s.gain += Clamp(want - s.gain, -fade_step, fade_step);

    out[f * 2] = int16_t(Clamp(warm_l * breath, -1, 1) * 32767);
    out[f * 2 + 1] = int16_t(Clamp(warm_r * breath, -1, 1) * 32767);
    s.frame++;
  }

  for (int i = 0; i < 8; i++) {
    s.phase_l[i] -= int(s.phase_l[i]);
    s.phase_r[i] -= int(s.phase_r[i]);
  }
  s.pluck_phase -= int(s.pluck_phase);
  s.sub_l -= int(s.sub_l);
  s.sub_r -= int(s.sub_r);
  s.lfo_slow -= int(s.lfo_slow);
  s.lfo_mid -= int(s.lfo_mid);
}

// AudioQueueStart fails while the app is not yet in front, which a launch can be, and
// an interruption stops a queue without saying so. It is also harmless on a running
// queue, so every return to the front simply asks again.
void StartQueue() {
  if (!g_queue || g_stopping) return;
  XenraMenuAudioSession();
  const OSStatus started = AudioQueueStart(g_queue, nullptr);
  AVAudioSession* session = AVAudioSession.sharedInstance;
  XenraLog([NSString
      stringWithFormat:@"ambient: start %d, gain %.2f, device volume %.2f, %@, route %@",
                       int(started), g_target_gain.load(), session.outputVolume,
                       session.category,
                       session.currentRoute.outputs.firstObject.portType]);
}

void WatchTheApp() {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    void (^again)(NSNotification*) = ^(NSNotification*) {
      StartQueue();
    };
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:again];
    [center addObserverForName:AVAudioSessionInterruptionNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:again];
  });
}

void TearDown() {
  if (!g_queue) return;
  AudioQueueDispose(g_queue, true);
  g_queue = nullptr;
}

void Fill(void*, AudioQueueRef queue, AudioQueueBufferRef buffer) {
  if (g_stopping && g_voice.gain <= 0) {
    // Buffers keep circulating: a start can still cancel this.
    memset(buffer->mAudioData, 0, kBlockFrames * 4);
    if (!g_finishing) {
      g_finishing = true;
      // Disposing from its own callback would deadlock.
      dispatch_async(dispatch_get_main_queue(), ^{
        g_finishing = false;
        if (g_stopping) TearDown();
      });
    }
  } else {
    Render(static_cast<int16_t*>(buffer->mAudioData));
  }
  buffer->mAudioDataByteSize = kBlockFrames * 4;
  AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}

}  // namespace

void XenraMenuAudioSession(void) {
  // Playback, because iPadOS has a Silent Mode and no switch to show it is on, so
  // Ambient looks like a broken app. Mixing keeps other apps' sound going.
  AVAudioSession* session = AVAudioSession.sharedInstance;
  NSError* error = nil;
  if (![session setCategory:AVAudioSessionCategoryPlayback
                withOptions:AVAudioSessionCategoryOptionMixWithOthers
                      error:&error] ||
      ![session setActive:YES error:&error]) {
    XenraLog([NSString stringWithFormat:@"ambient: session %@", error]);
  }
}

void XenraAmbientStart(void) {
  const BOOL enabled = [[XenraSettings stringForKey:@"music.enabled"
                                           fallback:@"true"] isEqual:@"true"];
  const int volume =
      [[XenraSettings stringForKey:@"music.volume" fallback:@"55"] intValue];
  if (!enabled || volume <= 0) {
    XenraAmbientStop();
    return;
  }
  g_palette = [XenraSettings console] == XenraConsole360 ? &kPaletteX360
                                                         : &kPaletteXbox;
  g_target_gain = volume / 100.0f * 1.05f;
  g_stopping = false;
  if (g_queue) {
    StartQueue();
    return;
  }

  for (int i = 0; i <= kTableSize; i++) {
    g_sine[i] = float(std::sin(2.0 * M_PI * i / kTableSize));
  }
  ResetVoice();
  XenraMenuAudioSession();
  WatchTheApp();

  AudioStreamBasicDescription format = {};
  format.mSampleRate = kSampleRate;
  format.mFormatID = kAudioFormatLinearPCM;
  format.mFormatFlags =
      kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
  format.mBytesPerPacket = 4;
  format.mFramesPerPacket = 1;
  format.mBytesPerFrame = 4;
  format.mChannelsPerFrame = 2;
  format.mBitsPerChannel = 16;
  // Audio is decoration: no queue means a silent menu, not a failed one.
  const OSStatus made =
      AudioQueueNewOutput(&format, Fill, nullptr, nullptr, nullptr, 0, &g_queue);
  if (made != noErr) {
    XenraLog([NSString stringWithFormat:@"ambient: no queue, %d", int(made)]);
    g_queue = nullptr;
    return;
  }
  for (int i = 0; i < kBuffers; i++) {
    AudioQueueBufferRef buffer;
    if (AudioQueueAllocateBuffer(g_queue, kBlockFrames * 4, &buffer) == noErr) {
      Fill(nullptr, g_queue, buffer);
    }
  }
  StartQueue();
}

void XenraAmbientStop(void) { g_stopping = true; }
