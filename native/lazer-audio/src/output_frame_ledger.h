/* Tracks which endpoint-queued frames represent source audio rather than silence or stale output. */
#ifndef LAZER_AUDIO_OUTPUT_FRAME_LEDGER_H
#define LAZER_AUDIO_OUTPUT_FRAME_LEDGER_H

#include <algorithm>
#include <cstdint>
#include <deque>

namespace lazer::audio {

class OutputFrameLedger {
public:
    void resetForSeek() noexcept {
        spans_.clear();
        queueDepth_ = 0;
        submissionsSinceObservation_ = 0;
        renderedSourceFrames_ = 0;
        needsResync_ = true;
    }

    [[nodiscard]] bool needsResync() const noexcept { return needsResync_; }

    void resync(int64_t queuedFrames) {
        spans_.clear();
        if (queuedFrames > 0) spans_.push_back({queuedFrames, 0});
        queueDepth_ = std::max<int64_t>(queuedFrames, 0);
        submissionsSinceObservation_ = 0;
        needsResync_ = false;
    }

    int64_t observeQueueDepth(int64_t queuedFrames) {
        queuedFrames = std::max<int64_t>(queuedFrames, 0);
        if (needsResync_) {
            resync(queuedFrames);
            return renderedSourceFrames_;
        }

        const int64_t submittedBeforeObservation = queueDepth_ + submissionsSinceObservation_;
        retireFrames(std::max<int64_t>(submittedBeforeObservation - queuedFrames, 0));
        queueDepth_ = queuedFrames;
        submissionsSinceObservation_ = 0;
        return renderedSourceFrames_;
    }

    void recordSubmission(int64_t outputFrames, int64_t sourceFrames) {
        if (outputFrames <= 0) return;
        const int64_t source = std::clamp<int64_t>(sourceFrames, 0, outputFrames);
        spans_.push_back({outputFrames, source});
        submissionsSinceObservation_ += outputFrames;
    }

    int64_t recordImmediateSourceFrames(int64_t sourceFrames) noexcept {
        renderedSourceFrames_ += std::max<int64_t>(sourceFrames, 0);
        return renderedSourceFrames_;
    }

    [[nodiscard]] int64_t renderedSourceFrames() const noexcept {
        return renderedSourceFrames_;
    }

private:
    struct Span {
        int64_t outputFrames;
        int64_t sourceFrames;
    };

    void retireFrames(int64_t retiredFrames) noexcept {
        while (retiredFrames > 0 && !spans_.empty()) {
            Span &span = spans_.front();
            const int64_t retired = std::min(retiredFrames, span.outputFrames);
            const int64_t sourceRetired = std::min(retired, span.sourceFrames);
            renderedSourceFrames_ += sourceRetired;
            span.outputFrames -= retired;
            span.sourceFrames -= sourceRetired;
            retiredFrames -= retired;
            if (span.outputFrames == 0) spans_.pop_front();
        }
    }

    std::deque<Span> spans_;
    int64_t queueDepth_ = 0;
    int64_t submissionsSinceObservation_ = 0;
    int64_t renderedSourceFrames_ = 0;
    bool needsResync_ = true;
};

}  // namespace lazer::audio

#endif  // LAZER_AUDIO_OUTPUT_FRAME_LEDGER_H
