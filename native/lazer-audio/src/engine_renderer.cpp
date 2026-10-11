#include "engine.h"
#include "engine_internal.h"
#include "engine_source_slot.h"
#include "dop_packer.h"
#include "output_frame_ledger.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>

extern "C" {
#include <libavutil/avutil.h>
#include <libavcodec/version.h>
#include <libavformat/version.h>
#include <libswresample/version.h>
}

namespace lazer::audio {
using namespace engine_detail;
void Engine::renderLoop() {
    std::string error;
    const int32_t threadSetup = output_->enterRenderThread(error);
    if (threadSetup != LazerAudioOk) {
        setError(error.empty() ? "the output backend could not initialise its render thread" : error,
            threadSetup);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventDeviceLost, threadSetup, currentPositionMillis());
        output_->leaveRenderThread();
        return;
    }

    const size_t blockFrames = std::max(kRenderBlockFrames,
        static_cast<size_t>(std::max(outputSession_.bufferFrames, 1)));
    std::vector<uint8_t> block(blockFrames *
        static_cast<size_t>(std::max(outputSession_.target.frameBytes(), 1)));
    uint64_t seenFlush = ring_.flushSequence();
    const auto waitForOutput = [this, &error]() {
        error.clear();
        const OutputWaitResult result = output_->waitForReady(kRenderWaitMillis, error);
        if (result == OutputWaitResult::Ready) return 1;
        if (result == OutputWaitResult::Timeout) return 0;
        setError(error.empty() ? "the output backend failed while waiting for a period" : error,
            LazerAudioErrorDevice);
        bitPerfectActive_.store(false, std::memory_order_release);
        publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
        return -1;
    };
    const auto publishTrackChanged = [this, &seenFlush]() {
        if (seekFlushRequested_.load(std::memory_order_acquire) ||
            ring_.flushSequence() != seenFlush) return;
        int64_t boundary = pendingTrackChangedFrame_.load(std::memory_order_acquire);
        if (boundary < 0 || !pendingPresentationReady_.load(std::memory_order_acquire) ||
            renderedFrames_.load(std::memory_order_acquire) < boundary) return;
        bool committed = false;
        {
            std::lock_guard sourceGuard(sourceMutex_);
            int64_t expected = boundary;
            if (!seekFlushRequested_.load(std::memory_order_acquire) &&
                ring_.flushSequence() == seenFlush &&
                pendingTrackChangedFrame_.compare_exchange_strong(
                    expected, -1, std::memory_order_acq_rel)) {
                presentationDescription_ = std::move(pendingPresentationDescription_);
                presentationSeekTargetMillis_ = pendingPresentationSeek_.load(
                    std::memory_order_acquire)
                    ? source_->source.seekTargetMillis()
                    : pendingPresentationSeekTargetMillis_;
                trackStartOutputFrame_.store(boundary, std::memory_order_release);
                pendingPresentationReady_.store(false, std::memory_order_release);
                pendingPresentationSeek_.store(false, std::memory_order_release);
                committed = true;
            }
        }
        if (committed) {
            /* Event callbacks may synchronously query the snapshot or stream info. */
            raise(LazerAudioEventTrackChanged, 0, currentPositionMillis());
        }
    };
    const auto activeDurationMillis = [this]() {
        std::lock_guard sourceGuard(sourceMutex_);
        return source_ == nullptr ? int64_t{0} : source_->source.description().durationMillis;
    };

    OutputFrameLedger outputFrameLedger;

    while (!cancelled_.load(std::memory_order_acquire)) {
        const uint64_t flush = ring_.flushSequence();
        if (flush != seenFlush) {
            /* A seek cleared the ring: the frames written before it no longer describe the position. */
            seenFlush = flush;
            /* The producer already reset session counters when it consumed seekFlushRequested_.
             * Reset only the render-side counters here; resetting acceptedFrames_ a second time
             * could hide a short post-seek tail from the producer's clean-EOF handling. */
            writtenFrames_.store(0, std::memory_order_release);
            renderedFrames_.store(0, std::memory_order_release);
            exclusiveInFlightAudioFrames_.store(0, std::memory_order_release);
            outputFrameLedger.resetForSeek();
            /* A seek flush discards any underrun state associated with stale queued frames. */
            underrunActive_.store(0, std::memory_order_release);
        }

        if (paused_.load(std::memory_order_acquire)) {
            if (waitForOutput() < 0) break;
            sleepIdle();
            continue;
        }

        const bool fixedPeriod = outputSession_.writeMode == OutputWriteMode::FixedPeriod;
        if (fixedPeriod) {
            const int32_t waitResult = waitForOutput();
            if (waitResult <= 0) {
                if (waitResult < 0) break;
                continue;
            }
            const int32_t justPlayed = exclusiveInFlightAudioFrames_.exchange(
                0, std::memory_order_acq_rel);
            if (flush != seenFlush) {
                /* A seek invalidates queued source frames; discard their old position accounting. */
                seenFlush = flush;
                writtenFrames_.store(0, std::memory_order_release);
                renderedFrames_.store(0, std::memory_order_release);
            } else if (justPlayed > 0) {
                renderedFrames_.fetch_add(justPlayed, std::memory_order_release);
            }
            publishTrackChanged();
        }

        if (pumpFinished_.load(std::memory_order_acquire) && ring_.readableFrames() == 0) {
            /* A completed source's drain wait is not an underrun. */
            underrunActive_.store(0, std::memory_order_release);
            const OutputDrainResult drain = output_->drain(error);
            if (drain == OutputDrainResult::Error) {
                setError(error.empty() ? "the output backend failed while draining" : error,
                    LazerAudioErrorDevice);
                bitPerfectActive_.store(false, std::memory_order_release);
                publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                break;
            }
            if (drain == OutputDrainResult::Drained) {
                if (!endedRaised_.exchange(true)) {
                    publishTerminal(LazerAudioEventEnded, 0, activeDurationMillis());
                }
                break;
            }
            if (waitForOutput() < 0) break;
            continue;
        }

        error.clear();
        const int32_t queuedBeforeWrite = outputSession_.queueDepthAvailable
            ? output_->queuedFrames(error) : 0;
        if (queuedBeforeWrite < 0) {
            setError(error.empty() ? "the output backend could not report its queued frames" : error,
                LazerAudioErrorDevice);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        if (!fixedPeriod && outputSession_.queueDepthAvailable) {
            if (outputFrameLedger.needsResync()) {
                /* A seek flush clears software accounting while an endpoint may still have old
                 * carrier frames queued. Retire those as non-source audio after the queue drains. */
                outputFrameLedger.resync(queuedBeforeWrite);
            } else {
                renderedFrames_.store(outputFrameLedger.observeQueueDepth(queuedBeforeWrite),
                    std::memory_order_release);
                publishTrackChanged();
            }
        }
        error.clear();
        int32_t room = output_->writableFrames(error);
        if (room < 0) {
            setError(error.empty() ? "the output backend could not report writable frames" : error,
                LazerAudioErrorDevice);
            bitPerfectActive_.store(false, std::memory_order_release);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        if (!fixedPeriod) room = std::min(room, static_cast<int32_t>(kRenderBlockFrames));
        if (room <= 0) {
            if (waitForOutput() < 0) break;
            continue;
        }

        /* At a queued boundary, never manufacture a short fixed-period packet or silence while the
         * successor decoder is still filling PCM. A sustained network underrun may stall the device
         * clock, but it cannot advance or corrupt the sample stream. */
        const int64_t boundary = pendingTrackChangedFrame_.load(std::memory_order_acquire);
        bool waitedForQueuedBoundary = false;
        if (boundary >= 0 && !pumpFinished_.load(std::memory_order_acquire)) {
            waitedForQueuedBoundary = true;
            underrunActive_.store(0, std::memory_order_release);
            const auto hasEnough = [&]() {
                const int32_t readable = ring_.readableFrames();
                return fixedPeriod
                    ? readable >= room || (readable > 0 && currentSourceEnded())
                    : readable > 0;
            };
            while (!cancelled_.load(std::memory_order_acquire) &&
                !pumpFinished_.load(std::memory_order_acquire) && !hasEnough()) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            if (cancelled_.load(std::memory_order_acquire)) break;
            if (!pumpFinished_.load(std::memory_order_acquire) && !hasEnough()) continue;
        }

        const int32_t frameBytes = std::max(outputSession_.target.frameBytes(), 1);
        const int32_t frames = ring_.read(block.data(), room);
        if (frames == 0 && !pumpFinished_.load(std::memory_order_acquire) &&
            !waitedForQueuedBoundary && currentSourceEnded()) {
            /* A clean decoder EOF can race the pump's final session notification. Wait for that
             * notification rather than submitting a silent fixed period between queued tracks. */
            sleepIdle();
            continue;
        }
        int32_t framesToWrite = fixedPeriod || frames == 0 ? room : frames;
        if (outputSession_.doP) {
            /* The shared formatter applies endpoint period semantics and advances the marker clock
             * only across frames included in this write submission. */
            framesToWrite = lazer::audio::prepareDopCarrierFrames(block.data(), room, frames,
                outputSession_.target.channels, fixedPeriod, dopNextMarker_);
            if (framesToWrite < 0) {
                setError("the DoP carrier formatter rejected the output frame layout",
                    LazerAudioErrorDevice);
                publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                break;
            }
        } else if (fixedPeriod && frames < room) {
            std::memset(block.data() + static_cast<size_t>(frames) * frameBytes,
                outputSession_.nativeDsd ? 0x69 : 0,
                static_cast<size_t>(room - frames) * frameBytes);
        }

        const bool sendingSilence = frames == 0;
        if (sendingSilence) {
            if (pumpFinished_.load(std::memory_order_acquire)) {
                const OutputDrainResult drain = output_->drain(error);
                if (drain == OutputDrainResult::Error) {
                    setError(error.empty() ? "the output backend failed while draining" : error,
                        LazerAudioErrorDevice);
                    bitPerfectActive_.store(false, std::memory_order_release);
                    publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
                    break;
                }
                if (drain == OutputDrainResult::Drained) {
                    if (!endedRaised_.exchange(true)) {
                        publishTerminal(LazerAudioEventEnded, 0, activeDurationMillis());
                    }
                    break;
                }
                if (waitForOutput() < 0) break;
                continue;
            }
            if (!outputSession_.doP) {
                std::memset(block.data(), outputSession_.nativeDsd ? 0x69 : 0,
                    static_cast<size_t>(room) * frameBytes);
            }
        }

        if (!outputSession_.doP) {
            framesToWrite = fixedPeriod || sendingSilence ? room : frames;
        }
        error.clear();
        const int32_t written = output_->write(block.data(), framesToWrite, error);
        if (written < 0 || (fixedPeriod && written != room) ||
            ((outputSession_.doP || outputSession_.nativeDsd) && written != framesToWrite)) {
            setError(error.empty() ? "the output backend rejected the submitted PCM frames" : error,
                written < 0 ? written : LazerAudioErrorDevice);
            publishTerminal(LazerAudioEventDeviceLost, 0, currentPositionMillis());
            break;
        }
        const int32_t submittedFrames = std::min(written, framesToWrite);
        const int32_t submittedSourceFrames = std::min(frames, submittedFrames);
        const int32_t paddedFrames = std::max(submittedFrames - submittedSourceFrames, 0);
        const bool currentSourceUnfinished = !pumpFinished_.load(std::memory_order_acquire) &&
            !currentSourceEnded();
        const bool countsAsUnderrun = paddedFrames > 0 && !waitedForQueuedBoundary &&
            !seekFlushRequested_.load(std::memory_order_acquire) &&
            ring_.flushSequence() == flush && currentSourceUnfinished;
        if (countsAsUnderrun) {
            underrunActive_.store(1, std::memory_order_release);
            underrunFrames_.fetch_add(static_cast<uint64_t>(paddedFrames),
                std::memory_order_acq_rel);
        } else {
            /* Full source data marks recovery; clean EOF padding and seek-flush output are ignored. */
            underrunActive_.store(0, std::memory_order_release);
        }
        if (fixedPeriod) {
            writtenFrames_.fetch_add(frames, std::memory_order_release);
            exclusiveInFlightAudioFrames_.store(frames, std::memory_order_release);
        } else if (written > 0) {
            writtenFrames_.fetch_add(written, std::memory_order_release);
            const int32_t sourceFrames = std::min(frames, written);
            if (outputSession_.queueDepthAvailable) {
                /* Keep an ordered audio/DoP-idle ledger. Total device queue depth includes idle
                 * carriers, but only source carriers should advance media position. */
                outputFrameLedger.recordSubmission(written,
                    sendingSilence ? 0 : sourceFrames);
            } else {
                /* Without a queue-depth API, preserve the old immediate-render assumption while
                 * excluding inserted idle carriers from source progress. */
                renderedFrames_.store(outputFrameLedger.recordImmediateSourceFrames(
                    sendingSilence ? 0 : sourceFrames), std::memory_order_release);
            }
            publishTrackChanged();
        }
        if (sendingSilence && !fixedPeriod && waitForOutput() < 0) break;
    }

    output_->leaveRenderThread();
}

std::string Engine::buildInformation() {
    std::string text = "FFmpeg avformat ";
    text += AV_STRINGIFY(LIBAVFORMAT_VERSION);
    text += ", avcodec ";
    text += AV_STRINGIFY(LIBAVCODEC_VERSION);
    text += ", swresample ";
    text += AV_STRINGIFY(LIBSWRESAMPLE_VERSION);
    return text;
}

void Engine::resetDopMarker() noexcept {
    dopNextMarker_ = 0x05;
}

}  // namespace lazer::audio
