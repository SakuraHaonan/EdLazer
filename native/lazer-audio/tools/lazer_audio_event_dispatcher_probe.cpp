#include "engine_event_dispatcher.h"

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <mutex>
#include <vector>

namespace {

struct ProbeEvents {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> delivered;
    bool firstCallbackEntered = false;
    bool releaseFirstCallback = false;
};

void onEvent(void *context, int32_t event, int32_t, int64_t) {
    auto *events = static_cast<ProbeEvents *>(context);
    std::unique_lock guard(events->mutex);
    events->delivered.push_back(event);
    if (event == LazerAudioEventReady) {
        events->firstCallbackEntered = true;
        events->changed.notify_all();
        events->changed.wait(guard, [events] { return events->releaseFirstCallback; });
    }
    events->changed.notify_all();
}

}  // namespace

int main() {
    ProbeEvents events;
    const LazerAudioEventHandler handler{onEvent, &events};
    lazer::audio::EngineEventDispatcher dispatcher(handler);
    dispatcher.beginSession(10);
    dispatcher.post(10, LazerAudioEventReady, 0, 0);
    {
        std::unique_lock guard(events.mutex);
        if (!events.changed.wait_for(guard, std::chrono::seconds(5), [&events] {
                return events.firstCallbackEntered;
            })) {
            std::cerr << "FAIL: first callback did not start\n";
            return 1;
        }
    }

    dispatcher.post(10, LazerAudioEventTrackChanged, 0, 1);
    dispatcher.beginSession(11);
    dispatcher.post(11, LazerAudioEventEnded, 0, 2);
    {
        std::lock_guard guard(events.mutex);
        events.releaseFirstCallback = true;
    }
    events.changed.notify_all();

    bool completed = false;
    {
        std::unique_lock guard(events.mutex);
        completed = events.changed.wait_for(guard, std::chrono::seconds(5), [&events] {
            return events.delivered.size() >= 2;
        });
    }
    dispatcher.shutdown();
    if (!completed || events.delivered.size() != 2 ||
        events.delivered[0] != LazerAudioEventReady ||
        events.delivered[1] != LazerAudioEventEnded) {
        std::cerr << "FAIL: stale queued callback was delivered across sessions\n";
        return 1;
    }
    std::cout << "PASS: event ordering and stale-session callback suppression\n";
    return 0;
}
