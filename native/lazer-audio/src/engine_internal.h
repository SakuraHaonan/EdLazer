/* Private engine policy helpers shared by the implementation units. */
#ifndef LAZER_AUDIO_ENGINE_INTERNAL_H
#define LAZER_AUDIO_ENGINE_INTERNAL_H

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <thread>

#include "internal.h"

namespace lazer::audio::engine_detail {

inline constexpr int32_t kRenderWaitMillis = 50;
inline constexpr int32_t kIdleSleepMillis = 3;
inline constexpr size_t kRenderBlockFrames = 960;
inline constexpr int32_t kDefaultBufferMillis = 120;
inline constexpr int32_t kMinimumBufferMillis = 60;
inline constexpr int32_t kMaximumBufferMillis = 2'000;

inline int32_t normalizeBufferMillis(int32_t value) noexcept {
    return std::min(value > 0 ? value : kDefaultBufferMillis, kMaximumBufferMillis);
}

inline bool validDspConfig(const LazerAudioDspConfig &dsp) noexcept {
    if (dsp.band_count > LAZER_AUDIO_MAX_EQ_BANDS ||
        !std::isfinite(dsp.preamp_db) || dsp.preamp_db < -12.0 || dsp.preamp_db > 12.0 ||
        !std::isfinite(dsp.limiter_threshold_db) || dsp.limiter_threshold_db < -120.0 ||
        dsp.limiter_threshold_db > 24.0 || (dsp.band_count > 0 && dsp.bands == nullptr)) {
        return false;
    }
    for (uint32_t index = 0; index < dsp.band_count; ++index) {
        const LazerAudioEqBand &band = dsp.bands[index];
        if (band.kind < LazerAudioEqBandPeak || band.kind > LazerAudioEqBandAllPass ||
            !std::isfinite(band.frequency_hz) || band.frequency_hz <= 0.0 ||
            !std::isfinite(band.gain_db) || band.gain_db < -12.0 || band.gain_db > 12.0 ||
            !std::isfinite(band.q) || band.q < 0.1 || band.q > 10.0) {
            return false;
        }
    }
    return true;
}

inline bool doPOutputApplies(
    int32_t dsdOutputMode, const StreamDescription &source) noexcept {
    return dsdOutputMode == LazerAudioDsdOutputRequireDoP && source.dsd && source.rawDsd &&
        (source.channels == 1 || source.channels == 2);
}

inline bool nativeDsdOutputApplies(
    int32_t dsdOutputMode, const StreamDescription &source) noexcept {
    return dsdOutputMode == LazerAudioDsdOutputRequireNative && source.dsd;
}

inline double replayGainLinear(double gainDb) noexcept {
    return std::pow(10.0, gainDb / 20.0);
}

inline void sleepIdle() {
    std::this_thread::sleep_for(std::chrono::milliseconds(kIdleSleepMillis));
}

}  // namespace lazer::audio::engine_detail

#endif  // LAZER_AUDIO_ENGINE_INTERNAL_H
