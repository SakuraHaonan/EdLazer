#include "engine.h"
#include "engine_internal.h"
#include "engine_source_slot.h"
#include "dop_packer.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>

namespace lazer::audio {
using namespace engine_detail;
int32_t Engine::play() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (currentState == LazerAudioStateIdle || currentState == LazerAudioStatePreparing ||
        currentState == LazerAudioStateFailed || currentState == LazerAudioStateStopped) {
        return LazerAudioErrorState;
    }

    if (outputSession_.primeBeforeStart && !streamStarted_) {
        const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
        const int32_t bufferFrames = outputSession_.bufferFrames;
        std::vector<uint8_t> firstBuffer(static_cast<size_t>(bufferFrames) * frameBytes, 0);
        const int32_t audioFrames = ring_.read(firstBuffer.data(), bufferFrames);
        if (outputSession_.doP) {
            const int32_t formattedFrames = prepareDopCarrierFrames(firstBuffer.data(),
                bufferFrames, audioFrames, outputSession_.target.channels, true, dopNextMarker_);
            if (formattedFrames != bufferFrames) {
                const std::string message = "the DoP carrier formatter rejected the priming buffer";
                setError(message, LazerAudioErrorDevice);
                bitPerfectActive_.store(false, std::memory_order_release);
                publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice, currentPositionMillis());
                return LazerAudioErrorDevice;
            }
        } else if (audioFrames < bufferFrames) {
            std::memset(firstBuffer.data() + static_cast<size_t>(audioFrames) * frameBytes,
                outputSession_.nativeDsd ? 0x69 : 0,
                static_cast<size_t>(bufferFrames - audioFrames) * frameBytes);
        }
        std::string primeError;
        const int32_t primed = output_->write(firstBuffer.data(), bufferFrames, primeError);
        if (primed != bufferFrames) {
            const std::string message = primeError.empty()
                ? "could not prefill the first exclusive audio buffer" : primeError;
            setError(message, primed < 0 ? primed : LazerAudioErrorDevice);
            bitPerfectActive_.store(false, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice, currentPositionMillis());
            return LazerAudioErrorDevice;
        }
        writtenFrames_.fetch_add(audioFrames, std::memory_order_release);
        exclusiveInFlightAudioFrames_.store(audioFrames, std::memory_order_release);
    }

    std::string error;
    const int32_t result = output_->start(error);
    if (result != LazerAudioOk) {
        setError(error, result);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventFailed, result, currentPositionMillis());
        return result;
    }
    streamStarted_ = true;
    paused_.store(false, std::memory_order_release);
    state_.store(LazerAudioStatePlaying, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::pause() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    const int32_t previous = state_.load(std::memory_order_acquire);
    if (previous != LazerAudioStatePlaying) return LazerAudioOk;
    paused_.store(true, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    std::string error;
    output_->stop(error);
    state_.store(LazerAudioStatePaused, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::stop() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    if (state_.load(std::memory_order_acquire) == LazerAudioStateIdle) return LazerAudioOk;
    const uint64_t generation = sessionGeneration_.fetch_add(1, std::memory_order_acq_rel) + 1;
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    outputSession_ = AudioOutputSession{};
    outputSampleRateSnapshot_.store(0, std::memory_order_release);
    retireCurrentSources();
    eventGeneration_.store(generation, std::memory_order_release);
    eventDispatcher_.beginSession(generation);
    {
        std::lock_guard sourceGuard(sourceMutex_);
        source_ = std::make_shared<SourceSlot>(this, config_.log);
    }
    bitPerfectActive_.store(false, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    state_.store(LazerAudioStateStopped, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::seek(int64_t positionMillis) {
    const auto activeState = [](int32_t state) {
        return state == LazerAudioStateReady || state == LazerAudioStatePlaying ||
            state == LazerAudioStatePaused;
    };
    if (!activeState(state_.load(std::memory_order_acquire))) return LazerAudioErrorState;
    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ == nullptr || !activeState(state_.load(std::memory_order_acquire))) {
        return LazerAudioErrorState;
    }
    if (pendingPresentationReady_.load(std::memory_order_acquire) &&
        pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0) {
        /* source_ is the decoder-active source. If it is B but the audible seam has not been
         * crossed, keep B's presentation event pending and rebase it after the seek flush. */
        pendingPresentationSeek_.store(true, std::memory_order_release);
    }
    /* Seeking invalidates the current starvation episode. Keep the session total cumulative. */
    underrunActive_.store(0, std::memory_order_release);
    const int64_t position = std::max<int64_t>(0, positionMillis);
    if (source_->prefetchStarted) source_->requestSeek(position);
    else {
        currentSource().requestSeek(position);
        seekFlushRequested_.store(true, std::memory_order_release);
    }
    return LazerAudioOk;
}

int32_t Engine::setVolume(double volume) {
    if (!std::isfinite(volume)) return LazerAudioErrorInvalidArgument;
    const double clamped = std::clamp(volume, 0.0, 1.0);
    if ((bitPerfectActive_.load(std::memory_order_acquire) ||
        dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) && clamped < 0.999999) {
        setError("software volume is unavailable while direct output is active; use the DAC volume",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    volume_.store(clamped, std::memory_order_release);
    volumeDirty_.store(true, std::memory_order_release);
    return LazerAudioOk;
}

int32_t Engine::setDsp(const LazerAudioDspConfig &dsp) {
    if (!validDspConfig(dsp)) return LazerAudioErrorInvalidArgument;
    if ((dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) &&
        (dsp.preamp_db != 0.0 || dsp.band_count > 0 || dsp.limiter_enabled != 0)) {
        setError("EQ and limiter are unavailable while direct DSD output is active",
            LazerAudioErrorUnsupported);
        return LazerAudioErrorUnsupported;
    }
    dsp_.requestConfig(dsp);
    return LazerAudioOk;
}

int32_t Engine::setDevice(const LazerAudioDeviceConfig &device) {
    std::lock_guard guard(apiMutex_);
    if (device.dsd_output_mode != LazerAudioDsdOutputConvertToPcm &&
        device.dsd_output_mode != LazerAudioDsdOutputRequireDoP &&
        device.dsd_output_mode != LazerAudioDsdOutputRequireNative) {
        return LazerAudioErrorInvalidArgument;
    }
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (currentState != LazerAudioStateIdle && currentState != LazerAudioStateStopped &&
        currentState != LazerAudioStateFailed) return LazerAudioErrorState;
    device_ = device;
    deviceId_.clear();
    if (device.device_id != nullptr && device.device_id[0] != L'\0') {
        deviceId_ = device.device_id;
        device_.device_id = deviceId_.c_str();
    } else {
        device_.device_id = nullptr;
    }
    bitPerfectActive_.store(false, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    device_.buffer_millis = normalizeBufferMillis(device_.buffer_millis);
    return LazerAudioOk;
}

void Engine::snapshot(LazerAudioSnapshot &out) {
    out.state = state_.load(std::memory_order_acquire);
    out.paused = paused_.load(std::memory_order_acquire) ? 1 : 0;
    /* Reader opening temporarily releases lifecycleMutex_ while its callback can block. Never read
     * AudioSource metadata in that phase; openReader is mutating it on the opening caller thread. */
    std::unique_lock lifecycleGuard(lifecycleMutex_, std::try_to_lock);
    const bool sourceIsStable = lifecycleGuard.owns_lock() &&
        state_.load(std::memory_order_acquire) != LazerAudioStatePreparing;
    if (sourceIsStable) {
        std::lock_guard sourceGuard(sourceMutex_);
        if (source_ != nullptr) {
            const bool transitionPending = pendingTrackChangedFrame_.load(
                std::memory_order_acquire) >= 0;
            const StreamDescription &description = transitionPending
                ? presentationDescription_ : currentSource().description();
            out.position_millis = currentPositionMillisLocked();
            out.duration_millis = description.durationMillis;
            out.buffered_percent = transitionPending
                ? presentationBufferedPercent_
                : static_cast<int32_t>(currentSource().bufferedFraction() * 100.0);
        } else {
            out.position_millis = 0;
            out.duration_millis = 0;
            out.buffered_percent = 0;
        }
    } else {
        out.position_millis = 0;
        out.duration_millis = 0;
        out.buffered_percent = 0;
    }
    out.error = lastErrorCode_.load(std::memory_order_acquire);
    out.underrun_active = underrunActive_.load(std::memory_order_acquire);
    out.underrun_frames = underrunFrames_.load(std::memory_order_acquire);
    const int32_t terminalEvent = terminalEvent_.load(std::memory_order_acquire);
    out.terminal_event = terminalEvent;
    out.terminal_detail = terminalEvent == -1
        ? 0 : terminalDetail_.load(std::memory_order_relaxed);
    out.terminal_position_millis = terminalEvent == -1
        ? 0 : terminalPositionMillis_.load(std::memory_order_relaxed);
}

void Engine::streamInfo(LazerAudioStreamInfo &out) {
    /* A callback can reenter this API while open/stop holds lifecycleMutex_. Never deadlock it;
     * return an unknown snapshot if the output lifecycle is changing. */
    std::unique_lock lifecycleGuard(lifecycleMutex_, std::try_to_lock);
    std::memset(&out, 0, sizeof(out));
    if (!lifecycleGuard.owns_lock() ||
        state_.load(std::memory_order_acquire) == LazerAudioStatePreparing) return;

    std::lock_guard sourceGuard(sourceMutex_);
    if (source_ == nullptr) return;
    const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
    const StreamDescription &description = transitionPending
        ? presentationDescription_ : currentSource().description();
    const size_t length = std::min(description.codec.size(), sizeof(out.codec) - 1);
    std::memcpy(out.codec, description.codec.data(), length);
    out.source_sample_rate = description.dsd ? 0 : description.sampleRate;
    out.source_channels = description.channels;
    out.source_bits_per_sample = description.dsd ? 0 : description.bitsPerSample;
    out.source_bitrate_kbps = description.bitrateKbps;
    out.lossless = description.lossless;
    out.source_format_kind = description.dsd
        ? LazerAudioSourceFormatDsd : LazerAudioSourceFormatPcm;
    out.source_dsd_rate_multiplier = description.dsdRateMultiplier;
    out.output_format_kind = LazerAudioOutputFormatPcm;
    out.output_peak_millidbfs = outputPeakMilliDbfs_.load(std::memory_order_acquire);
    out.limiter_gain_reduction_millidb = limiterGainReductionMilliDb_.load(std::memory_order_acquire);
    out.output_clipped_sample_count = outputClippedSampleCount_.load(std::memory_order_acquire);
    const int32_t currentState = state_.load(std::memory_order_acquire);
    if (output_ != nullptr && output_->isOpen() && currentState != LazerAudioStateFailed &&
        currentState != LazerAudioStateIdle && currentState != LazerAudioStatePreparing) {
        out.output_sample_rate = outputSession_.target.sampleRate;
        out.output_channels = outputSession_.target.channels;
        out.output_bits_per_sample = outputSession_.target.bitsPerSample == 0
            ? 32 : outputSession_.target.bitsPerSample;
        out.output_exclusive = outputSession_.exclusive ? 1 : 0;
        out.output_container_bits_per_sample = outputSession_.target.containerBitsPerSample > 0
            ? outputSession_.target.containerBitsPerSample : 32;
        out.output_is_float = outputSession_.target.bitsPerSample == 0 ? 1 : 0;
        out.output_format_initialized = 1;
        out.output_coreaudio_mixability_known = outputSession_.coreAudioMixabilityKnown ? 1 : 0;
        out.output_coreaudio_non_mixable = outputSession_.coreAudioStreamNonMixable ? 1 : 0;
        out.output_format_selection = outputSession_.formatSelection;
        out.output_telemetry_valid = outputTelemetryValid_.load(std::memory_order_acquire) &&
            !bitPerfectActive_.load(std::memory_order_acquire) &&
            !dopActive_.load(std::memory_order_acquire) &&
            !nativeDsdActive_.load(std::memory_order_acquire) ? 1 : 0;
        out.output_format_kind = outputSession_.nativeDsd
            ? LazerAudioOutputFormatNativeDsd
            : outputSession_.doP ? LazerAudioOutputFormatDoP : LazerAudioOutputFormatPcm;
        out.output_dsd_rate_multiplier = (outputSession_.doP || outputSession_.nativeDsd)
            ? description.dsdRateMultiplier : 0;
    }
    out.bit_perfect_active = bitPerfectActive_.load(std::memory_order_acquire) ? 1 : 0;
}

int64_t Engine::currentPositionMillis() const {
    std::lock_guard sourceGuard(sourceMutex_);
    return currentPositionMillisLocked();
}

int64_t Engine::currentPositionMillisLocked() const {
    const int32_t rate = outputSampleRateSnapshot_.load(std::memory_order_acquire);
    if (source_ == nullptr) return 0;
    const bool transitionPending = pendingTrackChangedFrame_.load(std::memory_order_acquire) >= 0;
    const int64_t seekTarget = transitionPending
        ? presentationSeekTargetMillis_ : currentSource().seekTargetMillis();
    if (rate <= 0) return seekTarget;
    const int64_t rendered = renderedFrames_.load(std::memory_order_acquire);
    const int64_t trackStart = trackStartOutputFrame_.load(std::memory_order_acquire);
    return seekTarget + std::max<int64_t>(rendered - trackStart, 0) * 1000 / rate;
}

void Engine::raise(int32_t event, int32_t detail, int64_t positionMillis) {
    eventDispatcher_.post(eventGeneration_.load(std::memory_order_acquire), event, detail,
        positionMillis);
}

void Engine::publishTerminal(int32_t event, int32_t detail, int64_t positionMillis) {
    bool expected = false;
    if (!terminalClaimed_.compare_exchange_strong(expected, true,
        std::memory_order_acq_rel, std::memory_order_acquire)) return;

    /* Keep the event, detail, and frozen event position from the same winning failure. Publish
     * the terminal state only after the whole record is visible to snapshot readers. */
    terminalDetail_.store(detail, std::memory_order_relaxed);
    terminalPositionMillis_.store(positionMillis, std::memory_order_relaxed);
    terminalEvent_.store(event, std::memory_order_release);
    state_.store(event == LazerAudioEventEnded ? LazerAudioStateStopped : LazerAudioStateFailed,
        std::memory_order_release);
    raise(event, detail, positionMillis);
}

void Engine::handleWorkerFailure(int32_t code) noexcept {
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    bitPerfectActive_.store(false, std::memory_order_release);
    lastErrorCode_.store(code, std::memory_order_release);
    try {
        setError("an audio engine worker terminated unexpectedly", code);
    } catch (...) {
        /* Preserve the numeric failure even if memory pressure prevents its text from being saved. */
    }
    publishTerminal(LazerAudioEventFailed, code, 0);
}

void Engine::setError(const std::string &text, int32_t code) {
    std::lock_guard guard(apiMutex_);
    setErrorLocked(text, code);
}

void Engine::setErrorLocked(const std::string &text, int32_t code) {
    lastError_ = text;
    lastErrorCode_.store(code, std::memory_order_release);
    log_.write(LazerAudioLogError, text);
}

bool Engine::shouldPump() const {
    /* The pump keeps feeding while the ring has room even when paused, which is what makes resume
     * instant; it parks only on a real pause with a full ring, handled by accept() returning 0. */
    return !cancelled_.load(std::memory_order_acquire);
}

bool Engine::isCancelled() const {
    return cancelled_.load(std::memory_order_acquire);
}

void Engine::onSeekApplied() {
    ring_.clearForProducer();
    if (nativeDsdActive_.load(std::memory_order_acquire)) nativeDsdPacker_.reset();
    resetTimelineForSeek();
    seekFlushRequested_.store(false, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
}

void Engine::resetTimelineForSeek() {
    writtenFrames_.store(0, std::memory_order_release);
    renderedFrames_.store(0, std::memory_order_release);
    acceptedFrames_.store(0, std::memory_order_release);
    trackStartOutputFrame_.store(0, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    std::lock_guard sourceGuard(sourceMutex_);
    if (pendingPresentationSeek_.load(std::memory_order_acquire) &&
        pendingPresentationReady_.load(std::memory_order_acquire)) {
        /* Frame zero is before the first post-seek sample. Wait for one rendered B frame so the
         * callback remains tied to the first output packet that actually contains the successor. */
        pendingTrackChangedFrame_.store(1, std::memory_order_release);
    } else {
        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingPresentationSeek_.store(false, std::memory_order_release);
    }
}

}  // namespace lazer::audio
