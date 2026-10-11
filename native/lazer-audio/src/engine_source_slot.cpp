#include "engine_source_slot.h"

#include <algorithm>
#include <new>
#include <string>
#include <utility>

namespace lazer::audio {

Engine::SourceSlot::SourceSlot(Engine *engine, LazerAudioLogHandler handler)
    : owner(engine), source(&log) {
    log.install(handler);
}

Engine::SourceSlot::~SourceSlot() {
    cancel();
    joinPrefetch();
    source.close();
}

bool Engine::SourceSlot::configurePrefetch(
    int32_t sampleRate, int32_t periodFrames, int32_t frameBytes) noexcept {
    constexpr size_t kMaximumQueuedPcmBytes = 64U * 1024U * 1024U;
    const size_t rate = static_cast<size_t>(std::max(sampleRate, 1));
    const size_t period = static_cast<size_t>(std::max(periodFrames, 1));
    const size_t capacity = std::max(rate, period * 4);
    const size_t watermark = std::min(capacity, std::max(rate / 4, period * 2));
    const size_t safeFrameBytes = static_cast<size_t>(std::max(frameBytes, 1));
    if (capacity > kMaximumQueuedPcmBytes / safeFrameBytes) return false;
    try {
        pcm = std::make_unique<QueuedPcmBuffer>(capacity, watermark, safeFrameBytes);
        return true;
    } catch (...) {
        return false;
    }
}

bool Engine::SourceSlot::startPrefetch() {
    std::lock_guard guard(prefetchThreadMutex);
    if (pcm == nullptr || prefetchStarted) return false;
    return launchPrefetchLocked();
}

bool Engine::SourceSlot::launchPrefetchLocked() {
    if (pcm == nullptr || cancelled.load(std::memory_order_acquire) ||
        prefetchRunning.load(std::memory_order_acquire)) return false;
    prefetchRunning.store(true, std::memory_order_release);
    try {
        prefetchThread = std::thread([this] {
            try {
                for (;;) {
                    const int32_t result = source.pump(*this);
                    std::unique_lock consumerGuard(consumerMutex);
                    if (!cancelled.load(std::memory_order_acquire) && source.hasPendingSeek()) {
                        consumerGuard.unlock();
                        continue;
                    }
                    pcm->finish(result, source.lastError(), source.reachedEndOfStream());
                    prefetchRunning.store(false, std::memory_order_release);
                    return;
                }
            } catch (const std::bad_alloc &) {
                finishAfterWorkerFailure(LazerAudioErrorNoMemory);
            } catch (...) {
                finishAfterWorkerFailure(LazerAudioErrorSource);
            }
        });
        prefetchStarted = true;
        return true;
    } catch (...) {
        prefetchRunning.store(false, std::memory_order_release);
        return false;
    }
}

void Engine::SourceSlot::finishAfterWorkerFailure(int32_t result) noexcept {
    try {
        pcm->finish(result, "queued worker failed", false);
    } catch (...) {
        pcm->finishWithoutMessage(result);
    }
    prefetchRunning.store(false, std::memory_order_release);
}

void Engine::SourceSlot::cancel() {
    cancelled.store(true, std::memory_order_release);
    if (pcm != nullptr) pcm->cancel();
    source.interruptReader();
}

void Engine::SourceSlot::joinPrefetch() {
    std::lock_guard guard(prefetchThreadMutex);
    if (prefetchThread.joinable() && prefetchThread.get_id() != std::this_thread::get_id()) {
        prefetchThread.join();
    }
}

void Engine::SourceSlot::requestSeek(int64_t positionMillis) {
    bool restartFinishedPrefetch = false;
    {
        std::lock_guard guard(consumerMutex);
        if (cancelled.load(std::memory_order_acquire)) return;
        source.requestSeek(positionMillis);
        if (pcm != nullptr) pcm->discardAll();
        if (pcm != nullptr && !prefetchRunning.load(std::memory_order_acquire)) {
            /* The successor can be fully decoded before its audible boundary. Reopen the staging
             * buffer while holding the consumer lock so the engine pump cannot mistake the just-
             * discarded, finished queue for the end of the whole session. */
            restartFinishedPrefetch = pcm->resetForRestart();
        }
        if (owner != nullptr) owner->seekFlushRequested_.store(true, std::memory_order_release);
    }
    if (restartFinishedPrefetch) {
        std::lock_guard guard(prefetchThreadMutex);
        if (prefetchThread.joinable()) prefetchThread.join();
        if (!launchPrefetchLocked() && pcm != nullptr) {
            pcm->finish(LazerAudioErrorNoMemory,
                "could not restart queued decoder after seek", false);
        }
    }
}

int32_t Engine::SourceSlot::accept(const uint8_t *bytes, int32_t frameCount) {
    std::lock_guard guard(consumerMutex);
    if (cancelled.load(std::memory_order_acquire) || pcm == nullptr || source.hasPendingSeek()) {
        return 0;
    }
    return pcm->accept(bytes, frameCount);
}

bool Engine::SourceSlot::shouldPump() const {
    return !cancelled.load(std::memory_order_acquire) && pcm != nullptr && pcm->shouldPump();
}

bool Engine::SourceSlot::isCancelled() const {
    return cancelled.load(std::memory_order_acquire) || pcm == nullptr || pcm->isCancelled();
}

void Engine::SourceSlot::onSeekApplied() {
    if (pcm != nullptr) {
        /* A queued source's initial CUE seek positions its private decoder before the track
         * boundary. It must not flush the active source's output ring. User seeks on an activated
         * queued source already request the session flush in requestSeek(). */
        std::lock_guard guard(consumerMutex);
        pcm->discardAll();
        return;
    }
    if (owner != nullptr) owner->onSeekApplied();
}

}  // namespace lazer::audio
