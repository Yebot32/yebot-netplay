/**
 ******************************************************************************
 * Xenra : iOS audio                                                          *
 ******************************************************************************
 *
 * The 360's audio on an AudioQueue, the counterpart of Android's AAudio driver
 * (emulator-core/src/main/cpp/xe_aaudio_audio_system.cpp).
 */

#ifndef XENRA_IOS_AUDIO_H_
#define XENRA_IOS_AUDIO_H_

#include <memory>

#include "xenia/apu/audio_system.h"

std::unique_ptr<xe::apu::AudioSystem> XenraCreateAudioSystem(
    xe::cpu::Processor* processor);

#endif  // XENRA_IOS_AUDIO_H_
