# Fix signal-record.sh Audio Volume and Mic Leak

## Background & Motivation
The user reports that recordings made with `~/bin/signal-record.sh` have persistently low audio volume compared to `~/bin/record-call.sh`. The current script's `MIX_FILTER` is flawed because it blindly takes only the left channel (`c0=c0|c1=c0`) after the `amix` stage, which can result in severe volume loss if the incoming Signal stream is unbalanced. Furthermore, since `signal-record.sh` isolates the audio using a PipeWire virtual sink (`signal_sink`), its raw baseline volume is often significantly lower than the post-fader speaker monitor captured by `record-call.sh`. Finally, local keyboard noise bleeds into the recording when the user is muted in-app.

## Objective
Implement the comprehensive fix proposed in `~/projects/dtu/audio-record/plans/260308-Fix-signal-record.sh-Volume-and-Mic-Leak.md` to normalize the loudness of the Signal-isolated recording so it matches `record-call.sh`, and resolve mic leak issues by adding explicit mic controls. This plan will be saved to `~/projects/dtu/audio-record/plans/260313-Fix-signal-record-volume.md` before implementation.

## Scope & Impact
- **Target File:** `~/bin/signal-record.sh`
- **Impact:** Ensures reliable, audible Signal recordings without manual post-processing, and prevents local background noise (keyboard typing) from bleeding into the file when it is not desired.

## Proposed Solution

1. **Rework the FFMPEG Audio Pipeline:**
   - **Fix the Channel Fold:** Instead of left-only duplication (`pan=stereo|c0=c0|c1=c0`), fold the Signal monitor to mono with both channels contributing: `0.5*FL + 0.5*FR` (or an equivalent `pan` filter).
   - **Explicit Branching:** Apply `SIGNAL_REMOTE_GAIN_DB` (default ~22dB) to the remote branch and `SIGNAL_MIC_GAIN_DB` to the mic branch independently.
   - **Mixing & Limiting:** Mix both branches using `amix=inputs=2:duration=longest:normalize=0`, apply a final `alimiter` to prevent clipping, and then upmix to stereo.

2. **Implement Explicit Mic Control (`--mic-mode`):**
   - **Modes:** `auto` (default), `on`, `off`.
   - **Behavior:** `off` fully excludes the mic branch; `on` always includes it. `auto` will attempt to dynamically determine if Signal's mic capture is active via PulseAudio/PipeWire state (falling back to remote-only if it cannot be determined, avoiding silent keyboard capture).
   - **Optional Flag:** Add `--mute-system-mic-during-recording` to hard-mute the physical mic and restore it on exit.

3. **Improve Self-Test Validation:**
   - Make the `--self-test` mode actually meaningful by validating both the remote and mic branches.
   - Test that the remote-only signal hits the target loudness window (-32 dB to -22 dB).
   - Enforce stricter pass/fail criteria (e.g., channel delta <= 1 dB) to prevent regressions.

## Implementation Plan

1. **Persist Plan:** Write this document to `~/projects/dtu/audio-record/plans/260313-Fix-signal-record-volume.md`.
2. **Update CLI Arguments & Variables in `signal-record.sh`:**
   - Add parsing for `--mic-mode <auto|on|off>` and `--mute-system-mic-during-recording`.
   - Update environment variable overrides (`SIGNAL_REMOTE_GAIN_DB`, `SIGNAL_MIC_GAIN_DB`).
3. **Refactor the ffmpeg `MIX_FILTER`:**
   - Adjust the filter string dynamically based on `--mic-mode`.
4. **Implement PulseAudio Source Detection (for `auto` mode):**
   - Query `pactl list source-outputs` to find if `ringrtc` currently has an active recording stream.
5. **Update the Self-Test Script:**
   - Replace the single-tone test with a dual-tone test.
   - Update `print_self_test_report()`.

## Verification
- **Static Checks:** Run `bash -n ~/bin/signal-record.sh`.
- **Self-Test Validation:** Run `signal-record.sh --self-test` and ensure it returns `PASS`.
- **Manual Audio Verification:** Do a live test call if possible, check that mean volume matches `record-call.sh` (~-30dB to -25dB).