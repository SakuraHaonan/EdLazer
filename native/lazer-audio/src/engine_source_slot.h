#ifndef LAZER_AUDIO_ENGINE_SOURCE_SLOT_H
#define LAZER_AUDIO_ENGINE_SOURCE_SLOT_H

#include <atomic>
#include <memory>
#include <mutex>
#include <thread>

#include "engine.h"
#include "queued_pcm_buffer.h"

namespace lazer::audio {

struct Engine::SourceSlot final : SourceConsumer {
    explicit SourceSlot(Engine *engine, LazerAudioLogHandler handler);
    ~SourceSlot() override;

    bool configurePrefetch(int32_t sampleRate, int32_t periodFrames, int32_t frameBytes) noexcept;
    bool startPrefetch();
    bool launchPrefetchLocked();
    void finishAfterWorkerFailure(int32_t result) noexcept;
    void cancel();
    void joinPrefetch();
    void requestSeek(int64_t positionMillis);

    int32_t accept(const uint8_t *bytes, int32_t frameCount) override;
    bool shouldPump() const override;
    bool isCancelled() const override;
    void onSeekApplied() override;

    LogProxy log;
    LazerAudioReader reader{};
    Engine *owner = nullptr;
    AudioSource source;
    uint64_t queueGeneration = 0;
    double replayGainLinear = 1.0;
    std::unique_ptr<QueuedPcmBuffer> pcm;
    std::thread prefetchThread;
    std::mutex prefetchThreadMutex;
    std::mutex consumerMutex;
    std::atomic<bool> cancelled{false};
    std::atomic<bool> prefetchRunning{false};
    bool prefetchStarted = false;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_ENGINE_SOURCE_SLOT_H
