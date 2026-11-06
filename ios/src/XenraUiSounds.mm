#import "XenraUiSounds.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

// UiSounds.kt, value for value. GAIN is a Float there, and it widens to the
// double below rather than to 0.22 exactly.
constexpr int kSampleRate = 22050;
constexpr int kVoices = 3;
constexpr double kGain = 0.22f;

// `decay` is the time constant, not the length: the buffer cuts the tail and the
// edges bring it to silence. Each partial truncates into the buffer as it is
// added, as Kotlin's toInt does.
void AddPartial(std::vector<int16_t>& pcm, double freq, double amp, double decay,
                double bend) {
  double phase = 0;
  for (size_t i = 0; i < pcm.size(); i++) {
    const double t = double(i) / kSampleRate;
    const double env = std::exp(-t / decay);
    phase += 2.0 * M_PI * (freq + bend * t) / kSampleRate;
    const double v = pcm[i] + std::sin(phase) * amp * env * 32767 * kGain;
    pcm[i] = int16_t(int(std::min(32767.0, std::max(-32768.0, v))));
  }
}

// 4 ms at each end, so neither can pop.
void ApplyEdges(std::vector<int16_t>& pcm) {
  const int ramp = std::max(1, int(kSampleRate * 0.004));
  for (int i = 0; i < ramp; i++) {
    const double g = double(i) / ramp;
    pcm[i] = int16_t(int(pcm[i] * g));
    const size_t j = pcm.size() - 1 - i;
    pcm[j] = int16_t(int(pcm[j] * g));
  }
}

std::vector<int16_t> RenderMove() {
  std::vector<int16_t> pcm(size_t(kSampleRate * 0.075));
  AddPartial(pcm, 880.0, 0.55, 0.030, 900.0);
  AddPartial(pcm, 1760.0, 0.14, 0.018, 0.0);
  ApplyEdges(pcm);
  return pcm;
}

void Put32(uint8_t* out, uint32_t value) { memcpy(out, &value, 4); }
void Put16(uint8_t* out, uint16_t value) { memcpy(out, &value, 2); }

// AVAudioPlayer takes a file, so the buffer gets the 44 bytes that make it one.
NSData* MakeWave(const std::vector<int16_t>& pcm) {
  const uint32_t bytes = uint32_t(pcm.size() * 2);
  NSMutableData* wave = [NSMutableData dataWithLength:44 + bytes];
  uint8_t* out = (uint8_t*)wave.mutableBytes;
  memcpy(out, "RIFF", 4);
  Put32(out + 4, 36 + bytes);
  memcpy(out + 8, "WAVEfmt ", 8);
  Put32(out + 16, 16);
  Put16(out + 20, 1);  // PCM
  Put16(out + 22, 1);  // mono
  Put32(out + 24, kSampleRate);
  Put32(out + 28, kSampleRate * 2);
  Put16(out + 32, 2);
  Put16(out + 34, 16);
  memcpy(out + 36, "data", 4);
  Put32(out + 40, bytes);
  memcpy(out + 44, pcm.data(), bytes);
  return wave;
}

NSArray<AVAudioPlayer*>* g_voices;
NSUInteger g_next;
#ifdef XENRA_UITEST
int g_count;
#endif

// The menus share an Ambient session with the music, but the music only sets it
// when it is switched on, and a game leaves Playback behind, which ignores the
// mute switch.
void UseAmbientSession(void) {
  AVAudioSession* session = AVAudioSession.sharedInstance;
  if (![session.category isEqualToString:AVAudioSessionCategoryAmbient]) {
    [session setCategory:AVAudioSessionCategoryAmbient error:nil];
  }
  [session setActive:YES error:nil];
}

void BuildVoices(void) {
  UseAmbientSession();
  NSData* wave = MakeWave(RenderMove());
  NSMutableArray<AVAudioPlayer*>* voices = [NSMutableArray array];
  for (int i = 0; i < kVoices; i++) {
    AVAudioPlayer* player = [[AVAudioPlayer alloc] initWithData:wave
                                                   fileTypeHint:AVFileTypeWAVE
                                                          error:nil];
    if (!player) continue;  // a silent menu, not a failed one
    [player prepareToPlay];
    [voices addObject:player];
  }
  g_voices = voices;
  g_next = 0;
}

}  // namespace

void XenraUiSoundsMove(void) {
#ifdef XENRA_UITEST
  g_count++;
#endif
  if (!g_voices) BuildVoices();
  if (!g_voices.count) return;
  // Round robin: navigation can retrigger faster than the cue finishes, and
  // restarting a voice mid-play cuts it off audibly.
  AVAudioPlayer* voice = g_voices[g_next];
  g_next = (g_next + 1) % g_voices.count;
  voice.currentTime = 0;
  if (![voice play]) {
    // A call or another app took the session away.
    UseAmbientSession();
    [voice play];
  }
}

void XenraUiSoundsRelease(void) {
  for (AVAudioPlayer* voice in g_voices) [voice stop];
  g_voices = nil;
}

#ifdef XENRA_UITEST
int XenraUiSoundsTestCount(void) { return g_count; }

NSString* XenraUiSoundsTestReport(void) {
  const std::vector<int16_t> pcm = RenderMove();
  int peak = 0;
  long long sum = 0;
  long long energy = 0;
  for (const int16_t sample : pcm) {
    peak = std::max(peak, std::abs(int(sample)));
    sum += sample;
    energy += (long long)sample * sample;
  }
  return [NSString stringWithFormat:@"samples=%zu peak=%d sum=%lld energy=%lld "
                                     "first=%d last=%d voices=%lu",
                                    pcm.size(), peak, sum, energy, int(pcm.front()),
                                    int(pcm.back()),
                                    (unsigned long)g_voices.count];
}
#endif
