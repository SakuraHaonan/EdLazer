#include "output_frame_ledger.h"

#include <iostream>

using lazer::audio::OutputFrameLedger;

namespace {

bool expect(bool condition, const char *message) {
    if (condition) return true;
    std::cerr << "FAIL: " << message << '\n';
    return false;
}

}  // namespace

int main() {
    OutputFrameLedger ledger;
    ledger.resync(10);
    ledger.recordSubmission(5, 5);
    if (!expect(ledger.observeQueueDepth(15) == 0,
            "newly submitted source frames must not be counted as rendered") ||
        !expect(ledger.observeQueueDepth(12) == 0,
            "stale queue frames must retire before source frames") ||
        !expect(ledger.observeQueueDepth(4) == 1,
            "source progress must advance only after the stale queue retires")) {
        return 1;
    }
    if (!expect(ledger.observeQueueDepth(0) == 5,
            "remaining source frames must retire before a later idle interval")) {
        return 1;
    }

    ledger.recordSubmission(4, 0);
    ledger.recordSubmission(6, 6);
    if (!expect(ledger.observeQueueDepth(10) == 5,
            "a full output queue must not advance source position") ||
        !expect(ledger.observeQueueDepth(6) == 5,
            "inserted silence must not advance source position") ||
        !expect(ledger.observeQueueDepth(4) == 7,
            "retired source frames must advance position after idle frames")) {
        return 1;
    }

    ledger.resetForSeek();
    if (!expect(ledger.needsResync(), "seek must request queue resynchronization")) return 1;
    ledger.resync(5);
    ledger.recordSubmission(4, 4);
    if (!expect(ledger.observeQueueDepth(9) == 0,
            "post-seek frames must wait behind old endpoint frames") ||
        !expect(ledger.observeQueueDepth(3) == 1,
            "new media progress must begin after stale post-seek frames retire")) {
        return 1;
    }

    ledger.resetForSeek();
    if (!expect(ledger.recordImmediateSourceFrames(12) == 12,
            "endpoints without queue depth must keep immediate progress accounting")) {
        return 1;
    }
    std::cout << "PASS: endpoint queue retirement, silence exclusion, and seek resynchronization\n";
    return 0;
}
