#include "engine.h"
#include "engine_internal.h"
#include "engine_source_slot.h"
#include "pcm_output.h"
#include "dop_packer.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>

namespace lazer::audio {
using namespace engine_detail;
int32_t Engine::accept(const uint8_t *bytes, int32_t frameCount) {
    if (frameCount <= 0) return 0;
    if (nativeDsdActive_.load(std::memory_order_acquire)) {
        const size_t wordBytes = static_cast<size_t>(outputSession_.target.containerBitsPerSample / 8);
        const size_t outputFrameBytes = static_cast<size_t>(outputSession_.target.frameBytes());
        if (wordBytes == 0 || outputFrameBytes == 0 || bytes == nullptr) return 0;
        const size_t possibleFrames = (static_cast<size_t>(frameCount) + wordBytes) / wordBytes;
        const size_t scratchFrames = possibleFrames;
        if (nativeDsdScratch_.size() < scratchFrames * outputFrameBytes) {
            nativeDsdScratch_.resize(scratchFrames * outputFrameBytes);
        }
        const size_t outputCapacityFrames = std::min(scratchFrames,
            static_cast<size_t>(std::max(ring_.writableFrames(), 0)));
        const NativeDsdPackResult packed = nativeDsdPacker_.pack(bytes,
            static_cast<size_t>(frameCount), nativeDsdScratch_.data(), outputCapacityFrames);
        if (packed.producedOutputFrames > 0) {
            const int32_t written = ring_.write(nativeDsdScratch_.data(),
                static_cast<int32_t>(packed.producedOutputFrames));
            if (written > 0) acceptedFrames_.fetch_add(written, std::memory_order_release);
        }
        if (packed.status == NativeDsdPackStatus::InvalidChannelCount ||
            packed.status == NativeDsdPackStatus::InvalidWordBytes ||
            packed.status == NativeDsdPackStatus::InvalidArgument ||
            packed.status == NativeDsdPackStatus::SizeOverflow) {
            return 0;
        }
        return static_cast<int32_t>(packed.consumedInputFrames);
    }
    if (volumeDirty_.exchange(false, std::memory_order_acq_rel)) {
        dsp_.setVolume(volume_.load(std::memory_order_acquire),
            static_cast<int32_t>(volumeRampMillis_.load(std::memory_order_acquire)));
    }
    int32_t frames = std::min(frameCount, ring_.writableFrames());
    if (frames <= 0) return 0;
    if (dspBypassed_ || dopActive_.load(std::memory_order_acquire) ||
        nativeDsdActive_.load(std::memory_order_acquire)) {
        const int32_t written = ring_.write(bytes, frames);
        if (written > 0) acceptedFrames_.fetch_add(written, std::memory_order_release);
        return written;
    }

    const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
    const size_t scratchFrames = convertScratch_.size() / static_cast<size_t>(frameBytes);
    frames = std::min(frames, static_cast<int32_t>(std::min(
        scratchFrames, static_cast<size_t>(frames))));
    if (frames <= 0) return 0;

    /* The block arrives as float32 at the device clock, so the DSP runs at the rate its filters were
     * designed for and the quantisation to the device depth happens on the way into the ring. */
    float *samples = const_cast<float *>(reinterpret_cast<const float *>(bytes));
    if (replayGainCurrentLinear_ != 1.0 || replayGainTargetLinear_ != 1.0) {
        const size_t channels = static_cast<size_t>(std::max(outputSession_.target.channels, 1));
        for (int32_t frame = 0; frame < frames; ++frame) {
            if (replayGainRampRemainingFrames_ > 0) {
                replayGainCurrentLinear_ += (replayGainTargetLinear_ - replayGainCurrentLinear_) /
                    static_cast<double>(replayGainRampRemainingFrames_);
                --replayGainRampRemainingFrames_;
                if (replayGainRampRemainingFrames_ == 0) {
                    replayGainCurrentLinear_ = replayGainTargetLinear_;
                }
            }
            float *frameSamples = samples + static_cast<size_t>(frame) * channels;
            for (size_t channel = 0; channel < channels; ++channel) {
                frameSamples[channel] = static_cast<float>(frameSamples[channel] * replayGainCurrentLinear_);
            }
        }
    }
    const double limiterReductionDb = dsp_.process(samples, static_cast<size_t>(frames));
    const size_t sampleCount = static_cast<size_t>(frames) *
        static_cast<size_t>(std::max(outputSession_.target.channels, 1));
    const int32_t peakMilliDbfs = samplePeakMilliDbfs(samples, sampleCount);
    const uint64_t clippedSamples = convertToOutput(samples, frames, convertScratch_.data());
    const int32_t written = ring_.write(convertScratch_.data(), frames);
    if (written > 0) {
        acceptedFrames_.fetch_add(written, std::memory_order_release);
        int32_t peakHold = outputPeakMilliDbfs_.load(std::memory_order_relaxed);
        while (peakHold < peakMilliDbfs && !outputPeakMilliDbfs_.compare_exchange_weak(
            peakHold, peakMilliDbfs, std::memory_order_release, std::memory_order_relaxed)) {}
        const double boundedReduction = std::clamp(limiterReductionDb, -180.0, 0.0);
        const int32_t reductionMilliDb = static_cast<int32_t>(std::llround(boundedReduction * 1000.0));
        int32_t reductionHold = limiterGainReductionMilliDb_.load(std::memory_order_relaxed);
        while (reductionHold > reductionMilliDb && !limiterGainReductionMilliDb_.compare_exchange_weak(
            reductionHold, reductionMilliDb, std::memory_order_release, std::memory_order_relaxed)) {}
        if (outputSession_.target.bitsPerSample != 0) {
            outputClippedSampleCount_.fetch_add(clippedSamples, std::memory_order_acq_rel);
        }
        outputTelemetryValid_.store(true, std::memory_order_release);
    }
    return written;
}

uint64_t Engine::convertToOutput(const float *source, int32_t frames, uint8_t *destination) {
    const size_t samples = static_cast<size_t>(frames) *
        static_cast<size_t>(std::max(outputSession_.target.channels, 1));
    if (outputSession_.target.bitsPerSample == 0) {
        std::memcpy(destination, source, samples * sizeof(float));
        return 0;
    }
    return convertIntegerPcm(source, samples, outputSession_.target.bitsPerSample,
        outputSession_.target.containerBitsPerSample, destination, ditherState_);
}

void Engine::pumpLoop() {
    const auto flushForSeek = [this] {
        if (!seekFlushRequested_.load(std::memory_order_acquire)) return;
        ring_.clearForProducer();
        if (nativeDsdActive_.load(std::memory_order_acquire)) nativeDsdPacker_.reset();
        resetTimelineForSeek();
        underrunActive_.store(0, std::memory_order_release);
        seekFlushRequested_.store(false, std::memory_order_release);
    };
    for (;;) {
        flushForSeek();
        std::shared_ptr<SourceSlot> active;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            active = source_;
        }
        if (active == nullptr || cancelled_.load(std::memory_order_acquire)) break;

        int32_t result = LazerAudioOk;
        bool reachedEof = false;
        std::string sourceError;
        if (!active->prefetchStarted) {
            result = active->source.pump(*this);
            reachedEof = active->source.reachedEndOfStream();
            sourceError = active->source.lastError();
        } else {
            const int32_t frameBytes = nativeDsdActive_.load(std::memory_order_acquire)
                ? std::max(outputSession_.target.channels, 1)
                : std::max(outputSession_.target.frameBytes(), 1);
            const int32_t scratchFrames = static_cast<int32_t>(queuedPcmScratch_.size() /
                static_cast<size_t>(frameBytes));
            while (!cancelled_.load(std::memory_order_acquire)) {
                flushForSeek();
                int32_t queued = 0;
                int32_t accepted = 0;
                {
                    std::lock_guard consumerGuard(active->consumerMutex);
                    queued = active->pcm->peekFrames(queuedPcmScratch_.data(), scratchFrames);
                    if (queued > 0) {
                        accepted = accept(queuedPcmScratch_.data(), queued);
                        if (accepted > 0) active->pcm->consumeFrames(accepted);
                    }
                }
                if (accepted > 0) continue;
                if (cancelled_.load(std::memory_order_acquire)) break;
                if (queued == 0 && active->pcm->finished() &&
                    active->pcm->queuedFrames() == 0) {
                    result = active->pcm->result();
                    sourceError = active->pcm->error();
                    reachedEof = active->pcm->reachedEof();
                    break;
                }
                if (queued == 0) active->pcm->waitForDataOrFinish();
                else sleepIdle();
            }
        }
        log_.write(LazerAudioLogDebug,
            "source pump returned code=" + std::to_string(result) +
            " eof=" + std::to_string(reachedEof ? 1 : 0));
        if (cancelled_.load(std::memory_order_acquire)) break;
        if (result != LazerAudioOk || !reachedEof) {
            pumpFinished_.store(true, std::memory_order_release);
            const int32_t errorCode = result == LazerAudioOk ? LazerAudioErrorSource : result;
            if (sourceError.empty()) sourceError = "audio source stopped before clean EOF";
            setError(sourceError, errorCode);
            endedRaised_.store(true, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, errorCode, currentPositionMillis());
            return;
        }
        bool started = false;
        std::string queueError;
        const int32_t queuedResult = tryStartQueuedSource(started, queueError);
        if (queuedResult != LazerAudioOk) {
            pumpFinished_.store(true, std::memory_order_release);
            if (queueError.empty()) queueError = "queued audio source failed before clean EOF";
            setError(queueError, queuedResult);
            endedRaised_.store(true, std::memory_order_release);
            publishTerminal(LazerAudioEventFailed, queuedResult, currentPositionMillis());
            return;
        }
        if (!started) {
            if (nativeDsdActive_.load(std::memory_order_acquire)) {
                while (nativeDsdPacker_.hasPendingInput() &&
                    !cancelled_.load(std::memory_order_acquire)) {
                    if (ring_.writableFrames() == 0) {
                        sleepIdle();
                        continue;
                    }
                    const NativeDsdPackResult flushed = nativeDsdPacker_.flush(
                        nativeDsdScratch_.data(), 1);
                    if (flushed.status != NativeDsdPackStatus::Ok ||
                        flushed.producedOutputFrames != 1) {
                        pumpFinished_.store(true, std::memory_order_release);
                        const std::string error =
                            "the final Native DSD word could not be padded at session EOF";
                        setError(error, LazerAudioErrorDecode);
                        endedRaised_.store(true, std::memory_order_release);
                        publishTerminal(LazerAudioEventFailed, LazerAudioErrorDecode,
                            currentPositionMillis());
                        return;
                    }
                    const int32_t written = ring_.write(nativeDsdScratch_.data(), 1);
                    if (written != 1) {
                        pumpFinished_.store(true, std::memory_order_release);
                        const std::string error =
                            "the output ring rejected the final Native DSD word";
                        setError(error, LazerAudioErrorDevice);
                        endedRaised_.store(true, std::memory_order_release);
                        publishTerminal(LazerAudioEventFailed, LazerAudioErrorDevice,
                            currentPositionMillis());
                        return;
                    }
                    acceptedFrames_.fetch_add(1, std::memory_order_release);
                }
                if (cancelled_.load(std::memory_order_acquire)) break;
            }
            if (active->queueGeneration != 0 &&
                pendingPresentationReady_.load(std::memory_order_acquire)) {
                /* Keep the engine pump alive until the activated successor has crossed its
                 * presentation boundary. A seek can restart a fully prefetched short successor;
                 * returning EOF here would otherwise strand its newly decoded PCM. */
                while (!cancelled_.load(std::memory_order_acquire) &&
                    pendingPresentationReady_.load(std::memory_order_acquire)) {
                    flushForSeek();
                    if (active->pcm->queuedFrames() > 0 || !active->pcm->finished()) break;
                    if (pendingPresentationSeek_.load(std::memory_order_acquire) &&
                        active->pcm->reachedEof() &&
                        acceptedFrames_.load(std::memory_order_acquire) == 0 &&
                        ring_.readableFrames() == 0) {
                        /* A seek exactly to EOF has no first successor frame to publish. Let the
                         * session drain cleanly instead of waiting forever for an inaudible seam. */
                        std::lock_guard sourceGuard(sourceMutex_);
                        pendingTrackChangedFrame_.store(-1, std::memory_order_release);
                        pendingPresentationReady_.store(false, std::memory_order_release);
                        pendingPresentationSeek_.store(false, std::memory_order_release);
                        break;
                    }
                    sleepIdle();
                }
                if (cancelled_.load(std::memory_order_acquire)) break;
                if (pendingPresentationReady_.load(std::memory_order_acquire)) continue;
            }
            /* The stream ran out of packets. The render thread drains only once the whole session
             * reaches EOF, so a prepared successor can append frames to the same output ring. */
            pumpFinished_.store(true, std::memory_order_release);
            log_.write(LazerAudioLogDebug, "pump reached final end of stream");
            break;
        }
    }
}

}  // namespace lazer::audio
