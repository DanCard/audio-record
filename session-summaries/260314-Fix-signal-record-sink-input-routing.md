# Session Summary: Fix `signal-record.sh` via Sink-Input Routing

## Problem Statement
`~/bin/signal-record.sh` was still producing much quieter recordings than `~/bin/record-call.sh` on the same Signal call.
The user provided a fresh comparison in `drone-tech-weekly/260314/` and asked that the repeated history of failed fixes be taken into account.

## Key Finding
The March 14 `signal-record.sh` recording was uniformly quiet on both channels. This was not the older near-silent-right-channel problem.
The remaining issue appeared to be that the Signal-isolated path was being captured below the sink-input gain path that makes `record-call.sh` sound normal.

## Changes Implemented
- Reworked `~/bin/signal-record.sh` to isolate Signal by matching its active PulseAudio/PipeWire sink-input from `pactl list sink-inputs`.
- Replaced low-level `pw-link` rewiring with `pactl move-sink-input`, moving only Signal into `signal_sink`.
- Added managed loopback from `signal_sink.monitor` back to the real speaker sink using `module-loopback`.
- Simplified the live FFmpeg path:
  - mic on: `amix=inputs=2:duration=longest:normalize=0`
  - mic off: record `signal_sink.monitor` directly
- Removed default live-path remote gain compensation:
  - `SIGNAL_REMOTE_GAIN_DB` now defaults to `0`
  - it is retained only as a self-test/diagnostic knob
- Improved startup diagnostics:
  - print matched Signal sink-input ID
  - print original sink and current sink-input volume
  - print resolved mic mode
- Improved cleanup:
  - restore the original Signal sink
  - unload loopback, null sink, and echo-cancel modules only when this script created them

## Validation Performed
- `bash -n /home/dcar/bin/signal-record.sh`
- `/home/dcar/bin/signal-record.sh --self-test --self-test-seconds 1 --mic-mode off tmp-bin-check`
  - self-test result: `PASS`
  - mean volume: `-31.0 dB`
  - channel delta: `0.00 dB`

## Repository Cleanup
- Deleted the duplicate tracked repo copy `~/projects/dtu/audio-record/signal-record.sh`.
- Declared `~/bin/signal-record.sh` the single canonical script.
- Updated repo notes to reflect that this repository now stores plans, summaries, and supporting material rather than the runnable Signal script itself.

## Remaining Risk
The actual loudness fix still needs a live same-call comparison after the sink-input change. The synthetic self-test only validates the FFmpeg path and shell wiring, not Signal’s live sink-input behavior on this machine.

## Recommended Next Check
1. Start a real Signal call.
2. Record the same call once with `~/bin/signal-record.sh` and once with `~/bin/record-call.sh`.
3. Compare loudness with `ffmpeg -af volumedetect`.
4. Confirm `signal-record.sh` is no longer catastrophically quiet and remains Signal-only.
