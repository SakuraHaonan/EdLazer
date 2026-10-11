/* Serializes caller-facing events away from playback and lifecycle locks. */
#ifndef LAZER_AUDIO_ENGINE_EVENT_DISPATCHER_H
#define LAZER_AUDIO_ENGINE_EVENT_DISPATCHER_H

#include <condition_variable>
#include <atomic>
#include <cstdint>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>

#include "lazer_audio_api.h"

namespace lazer::audio {

class EngineEventDispatcher {
public:
    explicit EngineEventDispatcher(LazerAudioEventHandler handler)
        : state_(std::make_shared<State>(handler)) {
        if (handler.on_event != nullptr) {
            thread_ = std::thread([state = state_] { run(state); });
        }
    }

    EngineEventDispatcher(const EngineEventDispatcher &) = delete;
    EngineEventDispatcher &operator=(const EngineEventDispatcher &) = delete;

    ~EngineEventDispatcher() { stop(); }

    void shutdown() noexcept { stop(); }

    void beginSession(uint64_t generation) noexcept {
        state_->generation.store(generation, std::memory_order_release);
    }

    void post(uint64_t generation, int32_t event, int32_t detail,
        int64_t positionMillis) noexcept {
        if (state_->handler.on_event == nullptr) return;
        try {
            {
                std::lock_guard guard(state_->mutex);
                if (state_->stopping) return;
                state_->pending.push_back(Event{generation, event, detail, positionMillis});
            }
            state_->changed.notify_one();
        } catch (...) {
            /* An event allocation must never terminate an audio worker or cross the C ABI. */
        }
    }

private:
    struct Event {
        uint64_t generation;
        int32_t type;
        int32_t detail;
        int64_t positionMillis;
    };

    struct State {
        explicit State(LazerAudioEventHandler callback) : handler(callback) {}

        LazerAudioEventHandler handler{};
        std::mutex mutex;
        std::condition_variable changed;
        std::deque<Event> pending;
        std::atomic<uint64_t> generation{0};
        bool stopping = false;
    };

    static void run(const std::shared_ptr<State> &state) noexcept {
        for (;;) {
            Event event{};
            {
                std::unique_lock guard(state->mutex);
                state->changed.wait(guard, [&] {
                    return state->stopping || !state->pending.empty();
                });
                if (state->stopping && state->pending.empty()) return;
                event = state->pending.front();
                state->pending.pop_front();
            }
            if (event.generation != state->generation.load(std::memory_order_acquire)) continue;
            try {
                state->handler.on_event(state->handler.context, event.type, event.detail,
                    event.positionMillis);
            } catch (...) {
                /* Exceptions must not escape a native worker or cross the C callback boundary. */
            }
        }
    }

    void stop() noexcept {
        if (!thread_.joinable()) return;
        {
            std::lock_guard guard(state_->mutex);
            state_->stopping = true;
            /* If destruction is requested by the callback itself, no further caller callbacks may
             * run after that callback destroys its context/engine. The worker owns State separately. */
            if (thread_.get_id() == std::this_thread::get_id()) state_->pending.clear();
        }
        state_->changed.notify_all();
        if (thread_.get_id() == std::this_thread::get_id()) thread_.detach();
        else thread_.join();
    }

    std::shared_ptr<State> state_;
    std::thread thread_;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_ENGINE_EVENT_DISPATCHER_H
