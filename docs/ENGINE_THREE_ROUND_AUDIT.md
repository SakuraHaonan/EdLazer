# Native audio engine: three-round audit

Date: 2026-10-11

Branch: `EngineEnvTest`
Audit base: `f0c91d5bab5a5bfcd12ccc0c63cd6278415df535`

## Round 1: architecture and boundaries

`native/lazer-audio/src/engine.cpp` is a roughly 1,900-line controller that currently owns source replacement and queue transitions, output-format negotiation, DSP setup, producer-side packing, render scheduling, timeline accounting, snapshots, and event publication. Decode, DSP, output backends, and byte/ring buffers already have separate modules, but the central engine still coordinates all of them through a large set of loosely grouped fields in `engine.h`.

The strongest refactor boundary is the playback session lifecycle: source preparation/activation, PCM production, endpoint rendering, and public control/snapshot work should be separate implementation units with explicit shared state. Keep the C ABI and format policy stable while introducing those boundaries.

## Round 2: concurrency, lifecycle, and callbacks

1. **Synchronous event callbacks can reenter locked engine APIs.** `Engine::open()` raised `Ready` and failures while holding lifecycle/API locks. Reentrant `stop()` or `setDevice()` could deadlock. The repair adds a serial engine-owned dispatcher, keeps callback invocation off caller/render threads, invalidates queued events from replaced sessions, and joins the dispatcher before engine state is destroyed. A callback already executing is allowed to finish.
2. **Snapshot reads output state without its lifecycle guard.** `snapshot()` holds `sourceMutex_` and calls `currentPositionMillisLocked()` (`engine.cpp:1118-1135`, `1206-1215`), which reads `outputSession_.target.sampleRate`. Open/teardown replace `outputSession_` under `lifecycleMutex_`, not `sourceMutex_` (`engine.cpp:295-303`, `301`). This is a data race during concurrent snapshot and reopen/stop.
3. **Seek accepts an inactive session.** `seek()` rejected only `Idle`; after `stop()` it could report success against an unopened source slot. The repair limits seek to Ready/Playing/Paused and rechecks state under the source lock.

## Round 3: formats, input bounds, and validation

1. **NaN volume reaches sample conversion.** `setVolume()` clamps but does not reject non-finite input (`engine.cpp:1066-1077`). `std::clamp(NaN, ...)` leaves NaN unchanged; the DSP volume ramp multiplies samples by it (`dsp_chain.cpp:168-209`), and the PCM quantizer passes it to `std::llround` (`pcm_output.cpp:20-25`). Direct-mode checks can also mistake NaN for full volume because `NaN < 0.999999` is false.
2. **DSP coefficients accept non-finite caller values.** `setDsp()` checks only band count (`engine.cpp:1080-1090`); `DspChain` copies and exponentiates preamp/gain/frequency/Q values (`dsp_chain.cpp:222-231`, `250-298`). NaN or extreme values can create non-finite coefficients and samples.
3. **Buffer duration is not bounded at the engine boundary.** `create()` and `setDevice()` replaced only non-positive values with the default. Large positive values could overflow sizing arithmetic. The repair caps requests at 2,000 ms while preserving positive low-latency requests such as the UI's 30 ms setting; internal scratch sizing uses checked 64-bit arithmetic and a 64 MiB allocation ceiling.

4. **Empty DSP config used a null pointer range.** A zero-band config can legally have `bands == nullptr`; `DspChain::requestConfig()` formed `bands + 0` and passed the null range to `vector::assign`. The repair explicitly clears the pending vector for zero bands, with a regression call in the engine probe.
5. **Worker exceptions could terminate the process.** Allocation/backend exceptions escaping the engine pump/render threads or a queued-source prefetch thread would invoke `std::terminate`. The engine workers now convert exceptions to terminal engine errors; the prefetch worker marks its bounded queue finished, including a no-message fallback if allocating the error text also fails.
6. **Non-finite decoded samples could reach `llround`.** Even with finite controls, damaged float decoder output can contain NaN/Inf. The DSP and integer quantizer now turn those samples into silence before packing and count them as clipped.
7. **Queued-source staging allocation was uncapped.** A successor cache sized from a negotiated sample rate/period could exceed the engine's regular scratch limit. Prefetch storage now has its own 64 MiB cap and returns `NoMemory` cleanly if it cannot be configured.

The current offline probes provide useful coverage for PCM/gapless/CUE, DoP, Native DSD, packing, recovery, and per-platform format policies. The latest recorded branch run, Build #214, passed all six Android, Windows, Linux, macOS, iOS simulator, and iOS device-build jobs. It is software/build evidence only: no physical DAC/device output was available, and the Linux runner skipped loopback capture because `snd-aloop` was absent.

## Refactor and verification sequence

- Preserve the ABI and extract event delivery and output timeline accounting into independently owned components.
- Split the engine implementation by lifecycle, control/snapshot, producer, and renderer responsibilities.
- Reject invalid numeric inputs and bound buffer arithmetic before allocation.
- Extend deterministic fake-output probes for the identified regressions, then run native CTest and the EngineEnvTest platform workflow.
- Keep physical endpoint, USB DAC, and acoustic checks listed as outstanding until devices are available.

## Refactor delivered in this branch

- Split engine implementation into `engine.cpp` (lifecycle and pipeline setup), `engine_queue.cpp`, `engine_control.cpp`, `engine_producer.cpp`, and `engine_renderer.cpp`; moved `SourceSlot` method bodies to `engine_source_slot.cpp`.
- Added `EngineEventDispatcher` for ordered, generation-scoped callbacks and `OutputFrameLedger` for output queue timeline accounting across silence and seek flushes.
- Added deterministic regressions for callback reentrancy, stale callback suppression, stopped seek, invalid numeric inputs, buffer upper/lower bounds, queue-depth frame retirement, empty DSP reset, and non-finite samples.
- The workspace has no local C++ compiler, CMake, or Ninja executable available. Branch CI must compile and run the native probes before the refactor can be called software-verified. Physical devices remain unavailable this round.
