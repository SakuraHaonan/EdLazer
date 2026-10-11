#include "engine.h"
#include "engine_internal.h"
#include "engine_source_slot.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>

namespace lazer::audio {
using namespace engine_detail;
int32_t Engine::queueReader(
    uint64_t queueGeneration, const LazerAudioReader &reader,
    const LazerAudioOpenParams &params) {
    if (reader.read == nullptr) return LazerAudioErrorInvalidArgument;
    if (!std::isfinite(params.replay_gain_db) || params.replay_gain_db < -60.0 ||
        params.replay_gain_db > 24.0) return LazerAudioErrorInvalidArgument;

    auto prepared = std::make_shared<SourceSlot>(this, config_.log);
    prepared->queueGeneration = queueGeneration;
    prepared->replayGainLinear = replayGainLinear(params.replay_gain_db);
    prepared->reader = reader;
    uint64_t generation = 0;
    TargetFormat target{};
    StreamDescription activeDescription;
    bool requireBitPerfect = false;
    bool requireDoP = false;
    bool requireNativeDsd = false;
    int32_t dsdOutputMode = LazerAudioDsdOutputConvertToPcm;
    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const int32_t currentState = state_.load(std::memory_order_acquire);
        if (currentState != LazerAudioStateReady && currentState != LazerAudioStatePlaying &&
            currentState != LazerAudioStatePaused) return LazerAudioErrorState;
        if (pumpFinished_.load(std::memory_order_acquire)) {
            return LazerAudioErrorState;
        }
        const uint64_t currentQueueGeneration = queueGeneration_.load(std::memory_order_acquire);
        if (queueGeneration <= currentQueueGeneration) return LazerAudioErrorState;
        generation = sessionGeneration_.load(std::memory_order_acquire);
        dsdOutputMode = device_.dsd_output_mode;
        requireDoP = dopActive_.load(std::memory_order_acquire);
        requireNativeDsd = nativeDsdActive_.load(std::memory_order_acquire);
        target = requireDoP || dspBypassed_ ? outputSession_.target : floatTarget_;
        if (requireDoP) target.doP = true;
        requireBitPerfect = !requireDoP && dspBypassed_;
        if (params.replay_gain_db != 0.0 && (requireDoP || requireNativeDsd || requireBitPerfect)) {
            return LazerAudioErrorUnsupported;
        }
        {
            std::lock_guard sourceGuard(sourceMutex_);
            if (nextSource_ != nullptr || preparingSource_ != nullptr || source_ == nullptr) {
                return LazerAudioErrorState;
            }
            activeDescription = source_->source.description();
        }
        const int32_t preparedReader = prepared->source.prepareReader(prepared->reader);
        if (preparedReader != LazerAudioOk) return preparedReader;
        queueGeneration_.store(queueGeneration, std::memory_order_release);
        std::lock_guard sourceGuard(sourceMutex_);
        preparingSource_ = prepared;
    }

    const auto abandonPreparation = [&] {
        std::lock_guard sourceGuard(sourceMutex_);
        if (preparingSource_ == prepared) preparingSource_.reset();
    };

    /* Opening a growing cache reader may block while FFmpeg probes its headers. Do this away from
     * the render thread and without holding either engine mutex. The pending slot is published first
     * so clear/stop can invoke its reader interruption callback if the probe blocks. */
    const int32_t opened = prepared->source.openReader(prepared->reader, params);
    if (opened != LazerAudioOk) {
        abandonPreparation();
        return opened;
    }

    const StreamDescription &preparedDescription = prepared->source.description();
    if ((doPOutputApplies(dsdOutputMode, preparedDescription) && !requireDoP) ||
        (nativeDsdOutputApplies(dsdOutputMode, preparedDescription) &&
            !requireNativeDsd)) {
        /* A queued PCM session may not cross into a direct-DSD policy without reopening the
         * endpoint; doing so would silently convert the successor through the old pipeline. */
        abandonPreparation();
        return LazerAudioErrorUnsupported;
    }
    if (requireDoP) {
        /* The existing endpoint carries DoP as exact packed 24-bit PCM. Keep one carrier clock,
         * channel layout, and raw DSD rate for the whole session; PCM/DST or a different DSD rate
         * must fall back to the regular stop/open path so the endpoint can be renegotiated. */
        const TargetFormat &sessionTarget = outputSession_.target;
        const bool compatibleRawDsd = activeDescription.dsd && activeDescription.rawDsd &&
            preparedDescription.dsd && preparedDescription.rawDsd &&
            activeDescription.dsdRateMultiplier > 0 &&
            preparedDescription.dsdRateMultiplier == activeDescription.dsdRateMultiplier &&
            preparedDescription.sampleRate == activeDescription.sampleRate &&
            preparedDescription.channels == activeDescription.channels &&
            (preparedDescription.channels == 1 || preparedDescription.channels == 2);
        const bool compatibleCarrier = outputSession_.doP && outputSession_.exclusive &&
            sessionTarget.sampleRate > 0 &&
            sessionTarget.sampleRate == target.sampleRate &&
            static_cast<int64_t>(sessionTarget.sampleRate) * 2 == preparedDescription.sampleRate &&
            sessionTarget.channels == target.channels &&
            sessionTarget.channels == preparedDescription.channels &&
            sessionTarget.bitsPerSample == 24 && sessionTarget.containerBitsPerSample == 24 &&
            target.bitsPerSample == 24 && target.containerBitsPerSample == 24 &&
            target.frameBytes() == target.channels * 3;
        if (!compatibleRawDsd || !compatibleCarrier) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    } else if (requireNativeDsd) {
        /* Native DSD successors are staged as raw byte frames. The session-level packer remains
         * owned by Engine so a partial U16/U32 word crosses the seam without 0x69 padding. */
        const TargetFormat &sessionTarget = outputSession_.target;
        const bool compatibleRawDsd = outputSession_.nativeDsd && outputSession_.exclusive &&
            activeDescription.dsd && activeDescription.rawDsd &&
            preparedDescription.dsd && preparedDescription.rawDsd &&
            activeDescription.dsdRateMultiplier > 0 &&
            preparedDescription.dsdRateMultiplier == activeDescription.dsdRateMultiplier &&
            preparedDescription.sampleRate == activeDescription.sampleRate &&
            preparedDescription.channels == activeDescription.channels &&
            (preparedDescription.channels == 1 || preparedDescription.channels == 2);
        const int32_t wordBytes = sessionTarget.containerBitsPerSample / 8;
        const bool compatibleWordFormat = sessionTarget.nativeDsd &&
            (wordBytes == 1 || wordBytes == 2 || wordBytes == 4) &&
            sessionTarget.bitsPerSample == sessionTarget.containerBitsPerSample &&
            sessionTarget.channels == preparedDescription.channels &&
            static_cast<int64_t>(sessionTarget.sampleRate) * wordBytes ==
                preparedDescription.sampleRate;
        if (!compatibleRawDsd || !compatibleWordFormat) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
        target = sessionTarget;
        target.sampleRate = preparedDescription.sampleRate;
        target.bitsPerSample = 8;
        target.containerBitsPerSample = 8;
        target.nativeDsd = false;
        target.nativeDsdRawBytes = true;
        target.nativeDsdBigEndian = true;
        target.nativeDsdWordBytes = wordBytes;
    } else {
        /* Keep the active device clock for the whole session. A different-rate successor must go
         * through the normal stop/open path so exclusive output can renegotiate before that track. */
        if (preparedDescription.sampleRate != activeDescription.sampleRate) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    }

    if (requireBitPerfect) {
        const StreamDescription &description = prepared->source.description();
        const bool exactContainer = target.containerBitsPerSample == target.bitsPerSample ||
            (target.bitsPerSample == 24 && target.containerBitsPerSample == 32);
        const bool exactPcmFormat = description.lossless && description.integerPcm &&
            description.canonicalChannelLayout && description.decoderFormatMatchesStream &&
            (description.channels == 1 || description.channels == 2) &&
            description.sampleRate == target.sampleRate &&
            description.channels == target.channels && description.bitsPerSample == target.bitsPerSample &&
            exactContainer &&
            (target.bitsPerSample == 16 || target.bitsPerSample == 24 || target.bitsPerSample == 32);
        if (!exactPcmFormat) {
            abandonPreparation();
            return LazerAudioErrorUnsupported;
        }
    }
    const int32_t formatted = prepared->source.setTargetFormat(target);
    if (formatted != LazerAudioOk) {
        abandonPreparation();
        return formatted;
    }

    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const int32_t currentState = state_.load(std::memory_order_acquire);
        if (sessionGeneration_.load(std::memory_order_acquire) != generation ||
            queueGeneration_.load(std::memory_order_acquire) != queueGeneration ||
            pumpFinished_.load(std::memory_order_acquire) ||
            (currentState != LazerAudioStateReady && currentState != LazerAudioStatePlaying &&
                currentState != LazerAudioStatePaused)) {
            abandonPreparation();
            return LazerAudioErrorState;
        }
        std::lock_guard sourceGuard(sourceMutex_);
        if (preparingSource_ != prepared || nextSource_ != nullptr) {
            return LazerAudioErrorState;
        }
        if (!prepared->configurePrefetch(target.sampleRate, outputSession_.bufferFrames,
                target.frameBytes())) {
            preparingSource_.reset();
            return LazerAudioErrorNoMemory;
        }
        if (!prepared->startPrefetch()) {
            preparingSource_.reset();
            return LazerAudioErrorNoMemory;
        }
        nextSource_ = prepared;
        preparingSource_.reset();
    }
    log_.write(LazerAudioLogDebug, requireNativeDsd
        ? "started bounded raw Native DSD byte prefetch for one compatible successor source"
        : "started bounded PCM prefetch for one compatible successor source");
    return LazerAudioOk;
}

int32_t Engine::clearQueuedReader(uint64_t queueGeneration) {
    std::shared_ptr<SourceSlot> retired;
    int32_t result = LazerAudioErrorState;
    {
        std::lock_guard lifecycleGuard(lifecycleMutex_);
        const uint64_t currentQueueGeneration = queueGeneration_.load(std::memory_order_acquire);
        if (queueGeneration <= currentQueueGeneration) return LazerAudioErrorState;
        queueGeneration_.store(queueGeneration, std::memory_order_release);
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != nullptr) {
            retired = std::move(nextSource_);
            result = LazerAudioQueueCleared;
        } else if (preparingSource_ != nullptr && preparingSource_->queueGeneration != 0 &&
            preparingSource_->queueGeneration == currentQueueGeneration) {
            retired = std::move(preparingSource_);
            result = LazerAudioQueueCleared;
        } else if (source_ != nullptr && source_->queueGeneration != 0 &&
            source_->queueGeneration == currentQueueGeneration) {
            result = LazerAudioQueueAlreadyActive;
        }
        if (retired != nullptr && !pendingPresentationReady_.load(std::memory_order_acquire)) {
            pendingTrackChangedFrame_.store(-1, std::memory_order_release);
        }
    }
    /* Interruption, worker join and close callbacks can reenter the owner; do them lock-free. */
    if (retired != nullptr) {
        retired->cancel();
        retired->joinPrefetch();
    }
    retired.reset();
    return result;
}

int32_t Engine::tryStartQueuedSource(bool &started, std::string &error) {
    started = false;
    error.clear();
    std::shared_ptr<SourceSlot> candidate;
    int64_t boundaryFrame = 0;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ == nullptr || cancelled_.load(std::memory_order_acquire)) {
            return LazerAudioOk;
        }
        candidate = nextSource_;
        boundaryFrame = acceptedFrames_.load(std::memory_order_acquire);
        if (nativeDsdActive_.load(std::memory_order_acquire) &&
            nativeDsdPacker_.hasPendingInput()) {
            /* The first packed successor word also contains the old track's final DSD bytes. */
            ++boundaryFrame;
        }
        pendingPresentationReady_.store(false, std::memory_order_release);
        pendingTrackChangedFrame_.store(boundaryFrame, std::memory_order_release);
    }

    /* The render thread knows the old stream has reached its boundary and must not pad a partial
     * fixed period while the queued decoder reaches its PCM watermark. No engine mutex is held. */
    const bool ready = candidate->pcm != nullptr && candidate->pcm->waitUntilReady();
    if (!ready) {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != candidate || cancelled_.load(std::memory_order_acquire)) {
            if (pendingTrackChangedFrame_.load(std::memory_order_acquire) == boundaryFrame) {
                pendingTrackChangedFrame_.store(-1, std::memory_order_release);
            }
            return LazerAudioOk;
        }
        if (candidate->pcm != nullptr && candidate->pcm->finished() &&
            candidate->pcm->queuedFrames() == 0) {
            const int32_t result = candidate->pcm->result();
            error = candidate->pcm->error();
            if (result != LazerAudioOk) return result;
            if (!candidate->pcm->reachedEof()) {
                error = error.empty() ? "queued audio source stopped before clean EOF" : error;
                return LazerAudioErrorSource;
            }
            error = "queued audio source produced no PCM frames";
            return LazerAudioErrorSource;
        }
        return LazerAudioOk;
    }

    std::shared_ptr<SourceSlot> retired;
    {
        std::lock_guard sourceGuard(sourceMutex_);
        if (nextSource_ != candidate || cancelled_.load(std::memory_order_acquire)) {
            if (pendingTrackChangedFrame_.load(std::memory_order_acquire) == boundaryFrame) {
                pendingTrackChangedFrame_.store(-1, std::memory_order_release);
            }
            return LazerAudioOk;
        }
        presentationDescription_ = source_->source.description();
        presentationSeekTargetMillis_ = source_->source.seekTargetMillis();
        presentationBufferedPercent_ = static_cast<int32_t>(
            source_->source.bufferedFraction() * 100.0);
        retired = std::move(source_);
        source_ = std::move(nextSource_);
        replayGainTargetLinear_ = source_->replayGainLinear;
        if (std::abs(replayGainTargetLinear_ - replayGainCurrentLinear_) < 1.0e-12) {
            replayGainCurrentLinear_ = replayGainTargetLinear_;
            replayGainRampRemainingFrames_ = 0;
        } else {
            replayGainRampRemainingFrames_ = std::max<int64_t>(
                1, static_cast<int64_t>(outputSession_.target.sampleRate) * 5 / 1000);
        }
        pendingPresentationDescription_ = source_->source.description();
        pendingPresentationSeekTargetMillis_ = source_->source.seekTargetMillis();
        pendingPresentationSeek_.store(false, std::memory_order_release);
        boundaryFrame = acceptedFrames_.load(std::memory_order_acquire);
        if (nativeDsdActive_.load(std::memory_order_acquire) &&
            nativeDsdPacker_.hasPendingInput()) {
            ++boundaryFrame;
        }
        pendingTrackChangedFrame_.store(boundaryFrame, std::memory_order_release);
        pendingPresentationReady_.store(true, std::memory_order_release);
    }
    retired.reset();
    log_.write(LazerAudioLogDebug,
        "successor source activated at output frame=" + std::to_string(boundaryFrame));
    started = true;
    return LazerAudioOk;
}

AudioSource &Engine::currentSource() noexcept {
    return source_->source;
}

const AudioSource &Engine::currentSource() const noexcept {
    return source_->source;
}

bool Engine::currentSourceEnded() const {
    std::lock_guard sourceGuard(sourceMutex_);
    return source_ == nullptr || source_->source.reachedEndOfStream();
}

}  // namespace lazer::audio
