#include "engine.h"
#include "engine_internal.h"
#include "engine_source_slot.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <new>
#include <string>
#include <utility>

namespace lazer::audio {
using namespace engine_detail;
Engine::Engine(LazerAudioEngineConfig config)
    : Engine(config, createPlatformAudioOutput()) {}

Engine::Engine(LazerAudioEngineConfig config, std::unique_ptr<AudioOutput> output)
    : config_(config), eventDispatcher_(config.events), output_(std::move(output)) {
    log_.install(config_.log);
    source_ = std::make_shared<SourceSlot>(this, config_.log);
    device_ = config_.device;
    if (config_.device.device_id != nullptr && config_.device.device_id[0] != L'\0') {
        deviceId_ = config_.device.device_id;
        device_.device_id = deviceId_.c_str();
    } else {
        device_.device_id = nullptr;
    }
    device_.buffer_millis = normalizeBufferMillis(device_.buffer_millis);
}

Engine::~Engine() {
    teardown();
    /* Join callbacks before the state/mutex members they may reenter are destroyed. */
    eventDispatcher_.shutdown();
}

Engine *Engine::create(const LazerAudioEngineConfig &config) {
    try {
        return create(config, createPlatformAudioOutput());
    } catch (...) {
        return nullptr;
    }
}

Engine *Engine::create(
    const LazerAudioEngineConfig &config, std::unique_ptr<AudioOutput> output) {
    if (config.abi_version != LAZER_AUDIO_ABI_VERSION) return nullptr;
    if (config.struct_size < sizeof(LazerAudioEngineConfig)) return nullptr;
    if (config.device.dsd_output_mode != LazerAudioDsdOutputConvertToPcm &&
        config.device.dsd_output_mode != LazerAudioDsdOutputRequireDoP &&
        config.device.dsd_output_mode != LazerAudioDsdOutputRequireNative) return nullptr;
    try {
        return new (std::nothrow) Engine(config, std::move(output));
    } catch (...) {
        return nullptr;
    }
}

void Engine::destroy() {
    stop();
    delete this;
}

void Engine::joinThreads() {
    if (renderThread_.joinable()) renderThread_.join();
    if (pumpThread_.joinable()) pumpThread_.join();
}

void Engine::cancelCurrentSources() {
    std::shared_ptr<SourceSlot> active;
    std::shared_ptr<SourceSlot> queued;
    std::shared_ptr<SourceSlot> preparing;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        active = source_;
        queued = nextSource_;
        preparing = preparingSource_;
    }
    if (active != nullptr) {
        if (active->prefetchStarted) active->cancel();
        else active->source.interruptReader();
    }
    if (queued != nullptr) {
        queued->cancel();
        queued->joinPrefetch();
    }
    if (preparing != nullptr) preparing->cancel();
}

void Engine::retireCurrentSources() {
    std::shared_ptr<SourceSlot> active;
    std::shared_ptr<SourceSlot> queued;
    std::shared_ptr<SourceSlot> preparing;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        active = std::move(source_);
        queued = std::move(nextSource_);
        preparing = std::move(preparingSource_);
        presentationDescription_ = {};
        pendingPresentationDescription_ = {};
        presentationSeekTargetMillis_ = 0;
        pendingPresentationSeekTargetMillis_ = 0;
        presentationBufferedPercent_ = 0;
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingPresentationSeek_.store(false, std::memory_order_release);
        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
    }
    for (const auto &slot : {active, queued, preparing}) {
        if (slot != nullptr) {
            slot->cancel();
            slot->joinPrefetch();
        }
    }
    active.reset();
    queued.reset();
    preparing.reset();
}

void Engine::teardown() {
    std::lock_guard lifecycleGuard(lifecycleMutex_);
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    outputSession_ = AudioOutputSession{};
    outputSampleRateSnapshot_.store(0, std::memory_order_release);
    retireCurrentSources();
    state_.store(LazerAudioStateIdle, std::memory_order_release);
}

int32_t Engine::open(
    const wchar_t *path, const LazerAudioReader *reader, const LazerAudioOpenParams &params) {
    /* One open at a time, and a fresh open always retires the previous stream first so a stale pump
     * or render thread can never write into the new pipeline. */
    if (path == nullptr && reader == nullptr) return LazerAudioErrorInvalidArgument;
    std::unique_lock lifecycleGuard(lifecycleMutex_);
    const uint64_t generation = sessionGeneration_.fetch_add(1, std::memory_order_acq_rel) + 1;
    cancelled_.store(true, std::memory_order_release);
    paused_.store(true, std::memory_order_release);
    cancelCurrentSources();
    joinThreads();
    if (output_ != nullptr) output_->close();
    outputSession_ = AudioOutputSession{};
    outputSampleRateSnapshot_.store(0, std::memory_order_release);
    retireCurrentSources();
    eventGeneration_.store(generation, std::memory_order_release);
    eventDispatcher_.beginSession(generation);
    state_.store(LazerAudioStatePreparing, std::memory_order_release);
    terminalClaimed_.store(false, std::memory_order_release);
    terminalDetail_.store(0, std::memory_order_relaxed);
    terminalPositionMillis_.store(0, std::memory_order_relaxed);
    terminalEvent_.store(-1, std::memory_order_release);
    {
        std::lock_guard sourceGuard(sourceMutex_);
        source_ = std::make_shared<SourceSlot>(this, config_.log);
    }
    std::unique_lock apiGuard(apiMutex_);
    cancelled_.store(false, std::memory_order_release);
    endedRaised_.store(false, std::memory_order_release);
    pumpFinished_.store(false, std::memory_order_release);
    writtenFrames_.store(0, std::memory_order_release);
    renderedFrames_.store(0, std::memory_order_release);
    acceptedFrames_.store(0, std::memory_order_release);
    trackStartOutputFrame_.store(0, std::memory_order_release);
    pendingTrackChangedFrame_.store(-1, std::memory_order_release);
    pendingPresentationReady_.store(false, std::memory_order_release);
    pendingPresentationSeek_.store(false, std::memory_order_release);
    seekFlushRequested_.store(false, std::memory_order_release);
    exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
    outputPeakMilliDbfs_.store(-120'000, std::memory_order_release);
    limiterGainReductionMilliDb_.store(0, std::memory_order_release);
    outputClippedSampleCount_.store(0, std::memory_order_release);
    outputTelemetryValid_.store(false, std::memory_order_release);
    underrunActive_.store(0, std::memory_order_release);
    underrunFrames_.store(0, std::memory_order_release);
    streamStarted_ = false;
    lastError_.clear();
    lastErrorCode_.store(LazerAudioOk, std::memory_order_release);
    bitPerfectActive_ = false;
    dopActive_.store(false, std::memory_order_release);
    nativeDsdActive_.store(false, std::memory_order_release);
    resetDopMarker();
    const LazerAudioOpenParams safeParams = params;
    if (!std::isfinite(safeParams.replay_gain_db) || safeParams.replay_gain_db < -60.0 ||
        safeParams.replay_gain_db > 24.0) {
        setErrorLocked("ReplayGain must be finite and within -60..24 dB",
            LazerAudioErrorInvalidArgument);
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    int32_t result = LazerAudioOk;
    std::shared_ptr<SourceSlot> openingSource;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        openingSource = source_;
        openingSource->replayGainLinear = replayGainLinear(safeParams.replay_gain_db);
        if (reader != nullptr) {
            openingSource->reader = *reader;
        }
    }
    if (reader != nullptr) {
        /* Bind the callbacks before publishing the slot. A concurrent stop can then cancel even if
         * it lands before FFmpeg begins probing the reader. */
        result = openingSource->source.prepareReader(openingSource->reader);
        if (result == LazerAudioOk) {
            std::lock_guard sourceGuard(sourceMutex_);
            preparingSource_ = openingSource;
        }
    }
    if (reader != nullptr && result == LazerAudioOk) {
        /* A caller reader can block while opening a growing HTTP cache. Publish its slot so stop or
         * replacement can interrupt it, then release engine locks while FFmpeg probes the stream. */
        apiGuard.unlock();
        lifecycleGuard.unlock();
        result = openingSource->source.openReader(openingSource->reader, safeParams);
        lifecycleGuard.lock();

        bool stillCurrent = false;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            stillCurrent = source_ == openingSource;
            if (preparingSource_ == openingSource) preparingSource_.reset();
        }
        if (sessionGeneration_.load(std::memory_order_acquire) != generation ||
            cancelled_.load(std::memory_order_acquire) || !stillCurrent) {
            lifecycleGuard.unlock();
            openingSource->source.close();
            return LazerAudioErrorState;
        }
        apiGuard.lock();
    } else if (reader == nullptr) {
        std::lock_guard sourceGuard(sourceMutex_);
        result = openingSource->source.openFile(path, safeParams);
    }
    if (result == LazerAudioOk) {
        std::lock_guard sourceGuard(sourceMutex_);
        presentationDescription_ = openingSource->source.description();
        presentationSeekTargetMillis_ = openingSource->source.seekTargetMillis();
        presentationBufferedPercent_ = static_cast<int32_t>(
            openingSource->source.bufferedFraction() * 100.0);
    }
    if (result != LazerAudioOk) {
        setErrorLocked(currentSource().lastError(), result);
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    const bool requireDoP = doPOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    const bool requireNativeDsd = nativeDsdOutputApplies(
        device_.dsd_output_mode, currentSource().description());
    if (safeParams.replay_gain_db != 0.0 &&
        (device_.bit_perfect != 0 || requireDoP || requireNativeDsd)) {
        setErrorLocked("ReplayGain changes samples and is unavailable in bit-perfect or direct DSD mode",
            LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }
    if ((requireDoP || requireNativeDsd) && device_.bit_perfect != 0) {
        setErrorLocked("direct DSD output and bit-perfect PCM output are separate modes",
            LazerAudioErrorInvalidArgument);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    if ((device_.bit_perfect != 0 || requireDoP || requireNativeDsd) &&
        volume_.load(std::memory_order_acquire) < 0.999999) {
        setErrorLocked("set software volume to 100% and use the DAC volume for direct output",
            LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }

    if (output_ == nullptr) {
        setErrorLocked("no local audio output backend is available", LazerAudioErrorUnsupported);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorUnsupported, 0);
        return LazerAudioErrorUnsupported;
    }

    AudioOutputRequest request;
    if (!wideStringToUtf8(device_.device_id, request.deviceId)) {
        setErrorLocked("the selected output device ID is not valid Unicode", LazerAudioErrorInvalidArgument);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorInvalidArgument, 0);
        return LazerAudioErrorInvalidArgument;
    }
    request.exclusive = device_.exclusive != 0 || requireDoP || requireNativeDsd;
    request.bufferMillis = normalizeBufferMillis(device_.buffer_millis);
    request.bitPerfect = device_.bit_perfect != 0;
    request.requireDoP = requireDoP;
    request.requireNativeDsd = requireNativeDsd;
    request.desired.sampleRate = currentSource().description().sampleRate;
    request.desired.channels = currentSource().description().channels;
    if (requireDoP) {
        request.desired.sampleRate = currentSource().description().sampleRate / 2;
        request.desired.bitsPerSample = 24;
        request.desired.containerBitsPerSample = 24;
        request.desired.doP = true;
    } else if (requireNativeDsd) {
        request.desired.nativeDsd = true;
    }

    std::string deviceError;
    result = output_->open(request, currentSource().description(), outputSession_, deviceError, &log_);
    if (result != LazerAudioOk) {
        setErrorLocked(deviceError, result);
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }
    outputSampleRateSnapshot_.store(outputSession_.target.sampleRate, std::memory_order_release);

    result = configurePipeline();
    if (result != LazerAudioOk) {
        setErrorLocked(lastError_, result);
        output_->close();
        currentSource().close();
        publishTerminal(LazerAudioEventFailed, result, 0);
        return result;
    }

    try {
        pumpThread_ = std::thread([this] {
            try {
                pumpLoop();
            } catch (const std::bad_alloc &) {
                handleWorkerFailure(LazerAudioErrorNoMemory);
            } catch (...) {
                handleWorkerFailure(LazerAudioErrorSource);
            }
        });
        renderThread_ = std::thread([this] {
            try {
                renderLoop();
            } catch (const std::bad_alloc &) {
                output_->leaveRenderThread();
                handleWorkerFailure(LazerAudioErrorNoMemory);
            } catch (...) {
                output_->leaveRenderThread();
                handleWorkerFailure(LazerAudioErrorDevice);
            }
        });
    } catch (...) {
        cancelled_.store(true, std::memory_order_release);
        /* A worker may be publishing an error while we join it. Do not hold apiMutex_ across join. */
        apiGuard.unlock();
        joinThreads();
        output_->close();
        outputSession_ = AudioOutputSession{};
        outputSampleRateSnapshot_.store(0, std::memory_order_release);
        apiGuard.lock();
        setErrorLocked("the engine could not start its playback workers", LazerAudioErrorNoMemory);
        publishTerminal(LazerAudioEventFailed, LazerAudioErrorNoMemory, 0);
        return LazerAudioErrorNoMemory;
    }
    int32_t expectedState = LazerAudioStatePreparing;
    if (state_.compare_exchange_strong(expectedState, LazerAudioStateReady,
        std::memory_order_acq_rel, std::memory_order_acquire)) {
        raise(LazerAudioEventReady, 0, currentPositionMillis());
    }
    return LazerAudioOk;
}

int32_t Engine::configurePipeline() {
    const StreamDescription &description = currentSource().description();
    const TargetFormat &target = outputSession_.target;
    const bool requireDoP = doPOutputApplies(device_.dsd_output_mode, description);
    const bool requireNativeDsd = nativeDsdOutputApplies(device_.dsd_output_mode, description);
    if (requireDoP != outputSession_.doP || requireNativeDsd != outputSession_.nativeDsd) {
        lastError_ = requireDoP
            ? "the selected output did not initialize the required DoP carrier format"
            : requireNativeDsd
                ? "the selected output did not initialize the required Native DSD format"
                : "the output initialized a DSD mode even though PCM output was requested";
        return LazerAudioErrorUnsupported;
    }
    nativeDsdActive_.store(false, std::memory_order_release);
    if (outputSession_.doP) {
        if (!description.dsd || !description.rawDsd || !outputSession_.exclusive ||
            target.sampleRate <= 0 || static_cast<int64_t>(target.sampleRate) * 2 !=
                description.sampleRate ||
            target.channels != description.channels || target.bitsPerSample != 24 ||
            target.frameBytes() != target.channels * 3) {
            lastError_ = "the initialized output does not match the raw DSD DoP carrier contract";
            return LazerAudioErrorUnsupported;
        }
        TargetFormat dopTarget = target;
        dopTarget.doP = true;
        const int32_t result = currentSource().setTargetFormat(dopTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        dspBypassed_ = false;
        dopActive_.store(true, std::memory_order_release);
    } else {
        dopActive_.store(false, std::memory_order_release);
    }
    if (outputSession_.nativeDsd) {
        const int32_t wordBytes = target.containerBitsPerSample / 8;
        if (!description.dsd || !description.rawDsd || !outputSession_.exclusive ||
            !target.nativeDsd || target.sampleRate <= 0 ||
            (target.containerBitsPerSample != 8 && target.containerBitsPerSample != 16 &&
                target.containerBitsPerSample != 32) ||
            target.bitsPerSample != target.containerBitsPerSample ||
            static_cast<int64_t>(target.sampleRate) * wordBytes != description.sampleRate ||
            target.channels != description.channels ||
            (target.channels != 1 && target.channels != 2)) {
            lastError_ = "the initialized output does not match the raw Native DSD format contract";
            return LazerAudioErrorUnsupported;
        }
        TargetFormat rawDsdTarget = target;
        rawDsdTarget.sampleRate = description.sampleRate;
        rawDsdTarget.bitsPerSample = 8;
        rawDsdTarget.containerBitsPerSample = 8;
        rawDsdTarget.nativeDsd = false;
        rawDsdTarget.nativeDsdRawBytes = true;
        rawDsdTarget.nativeDsdBigEndian = true;
        rawDsdTarget.nativeDsdWordBytes = wordBytes;
        const int32_t result = currentSource().setTargetFormat(rawDsdTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        nativeDsdPacker_ = NativeDsdPacker(static_cast<size_t>(target.channels),
            static_cast<size_t>(wordBytes), target.nativeDsdBigEndian);
        dspBypassed_ = false;
        nativeDsdActive_.store(true, std::memory_order_release);
    } else {
        nativeDsdPacker_ = NativeDsdPacker{};
    }
    const bool exactContainer = target.containerBitsPerSample == target.bitsPerSample ||
        (target.bitsPerSample == 24 && target.containerBitsPerSample == 32);
    const bool exactPcmFormat = description.lossless && description.integerPcm &&
        description.canonicalChannelLayout && description.decoderFormatMatchesStream &&
        (description.channels == 1 || description.channels == 2) &&
        description.sampleRate == target.sampleRate &&
        description.channels == target.channels && description.bitsPerSample == target.bitsPerSample &&
        exactContainer &&
        (target.bitsPerSample == 16 || target.bitsPerSample == 24 || target.bitsPerSample == 32);
    if (!outputSession_.doP && !outputSession_.nativeDsd &&
        device_.bit_perfect != 0 && !exactPcmFormat) {
        lastError_ = "bit-perfect output requires exact mono or stereo lossless integer PCM format";
        return LazerAudioErrorUnsupported;
    }
    if (!outputSession_.doP && !outputSession_.nativeDsd) {
        dspBypassed_ = device_.bit_perfect != 0 && outputSession_.exclusive && exactPcmFormat;
    }
    if (outputSession_.doP) {
        /* DoP words are an encoded DSD bitstream. They must reach the carrier untouched, with
         * software processing and quantization completely out of the chain. */
    } else if (outputSession_.nativeDsd) {
        /* Native DSD is a raw bitstream, so keep it out of the PCM DSP and float conversion path. */
    } else if (dspBypassed_) {
        /* Bit-perfect stream out: the decoded integer samples go straight to the device, which is why
         * the volume control must then belong to the amplifier or the DAC. */
        const int32_t result = currentSource().setTargetFormat(outputSession_.target);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
    } else {
        TargetFormat floatTarget;
        floatTarget.sampleRate = outputSession_.target.sampleRate;
        floatTarget.channels = outputSession_.target.channels;
        floatTarget.bitsPerSample = 0;
        floatTarget_ = floatTarget;
        const int32_t result = currentSource().setTargetFormat(floatTarget);
        if (result != LazerAudioOk) {
            lastError_ = currentSource().lastError();
            return result;
        }
        dsp_.configureFormat(outputSession_.engineFormat);
        dsp_.setVolume(volume_.load(std::memory_order_acquire),
            static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
    }

    constexpr size_t kMaximumScratchBytes = 64U * 1024U * 1024U;
    const int32_t frameBytes = outputSession_.target.frameBytes();
    const int64_t wantedFrames = std::max<int64_t>(
        static_cast<int64_t>(outputSession_.bufferFrames) * 3,
        static_cast<int64_t>(outputSession_.target.sampleRate) *
            std::max(device_.buffer_millis, kMinimumBufferMillis) / 1000);
    if (frameBytes <= 0 || wantedFrames <= 0 ||
        wantedFrames > std::numeric_limits<int32_t>::max() / 2) {
        lastError_ = "the negotiated output buffer exceeds the engine's supported frame range";
        return LazerAudioErrorUnsupported;
    }
    const size_t wantedFrameCount = static_cast<size_t>(wantedFrames);
    const size_t outputFrameBytes = static_cast<size_t>(frameBytes);
    if (wantedFrameCount > kMaximumScratchBytes / outputFrameBytes) {
        lastError_ = "the negotiated output buffer exceeds the engine's memory limit";
        return LazerAudioErrorNoMemory;
    }
    const size_t queuedScratchFrames = std::max(kRenderBlockFrames,
        static_cast<size_t>(std::max(outputSession_.bufferFrames, 1)));
    const size_t queuedFrameBytes = outputSession_.nativeDsd
        ? static_cast<size_t>(std::max(target.channels, 1)) * static_cast<size_t>(
            std::max(target.containerBitsPerSample / 8, 1))
        : outputFrameBytes;
    if (queuedScratchFrames > kMaximumScratchBytes / queuedFrameBytes ||
        (outputSession_.nativeDsd &&
            queuedScratchFrames > kMaximumScratchBytes / outputFrameBytes)) {
        lastError_ = "the negotiated output scratch buffers exceed the engine's memory limit";
        return LazerAudioErrorNoMemory;
    }
    try {
        ring_.reset(static_cast<int32_t>(wantedFrames), frameBytes);
        convertScratch_.assign(wantedFrameCount * outputFrameBytes, 0);
        queuedPcmScratch_.assign(queuedScratchFrames * queuedFrameBytes, 0);
        if (outputSession_.nativeDsd) {
            nativeDsdScratch_.assign(queuedScratchFrames * outputFrameBytes, 0);
        } else {
            nativeDsdScratch_.clear();
        }
    } catch (...) {
        lastError_ = "the engine could not allocate its negotiated audio buffers";
        return LazerAudioErrorNoMemory;
    }
    replayGainCurrentLinear_ = source_->replayGainLinear;
    replayGainTargetLinear_ = source_->replayGainLinear;
    replayGainRampRemainingFrames_ = 0;
    bitPerfectActive_.store(dspBypassed_, std::memory_order_release);
    return LazerAudioOk;
}

}  // namespace lazer::audio
