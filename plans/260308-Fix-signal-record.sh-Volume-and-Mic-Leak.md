# Fix `signal-record.sh` Loudness and Mic-Leak Behavior

## Summary
- Rework `~/bin/signal-record.sh` so the Signal-isolated recording lands near the same practical loudness as `record-call.sh` without relying on repeated one-off gain bumps.
- Stop assuming Signal's in-app mute controls the recording path. Add recording-side mic control with a best-effort Signal-mute follower and a safe fallback that prevents local keyboard noise from leaking into the file.

## Key Changes
- Add CLI/env controls:
  - `--mic-mode auto|on|off`
  - `SIGNAL_MIC_MODE` with default `auto`
  - `--mute-system-mic-during-recording` as an optional convenience flag that mutes `ORIGINAL_MIC` at start and restores its prior mute state on cleanup
  - Replace `SIGNAL_MIX_GAIN_DB` with `SIGNAL_REMOTE_GAIN_DB` and `SIGNAL_MIC_GAIN_DB`
- Change the audio pipeline in `~/bin/signal-record.sh`:
  - Replace the current `volume=${SIGNAL_MIX_GAIN_DB}` on `[0:a]` plus `pan=stereo|c0=c0|c1=c0` with an explicit branch graph
  - Fold the Signal monitor to mono with both channels contributing, not left-only duplication: treat remote audio as `0.5*FL + 0.5*FR`
  - Apply remote gain on the remote branch, optional mic gain on the mic branch, mix with `amix=normalize=0`, then apply one final limiter and stereo upmix
  - Keep output AAC/stereo and existing PipeWire Signal-isolation routing
- Implement mic control behavior:
  - `off`: do not include `echocancel_source` in the recording at all
  - `on`: always include `echocancel_source`
  - `auto` default: attempt to follow Signal's mic capture state by inspecting PulseAudio/PipeWire source outputs for the Signal client and subscribing to changes with `pactl subscribe`
  - In `auto`, if the Signal mic stream is muted, absent, or cannot be resolved within a short startup timeout, record remote-only and print a warning that the script fell back to safe mode
  - Do not use UI scraping (`xdotool`) as the primary mechanism; use PipeWire/Pulse state first and only warn on failure
- Improve user feedback:
  - Print a startup banner showing resolved mic mode: `AUTO (following Signal)`, `ON`, or `OFF`
  - If `auto` cannot be established, print a prominent reminder that Signal mute does not guarantee the recording mic is muted and that the script is falling back to remote-only
  - If `--mute-system-mic-during-recording` is used, print the original mute state and confirm restoration on exit
- Replace the current self-test with meaningful validation:
  - Remote-only self-test: asymmetric stereo remote tone, no mic branch, verifies channel fold and loudness target
  - Mixed self-test: distinct remote and mic tones, verifies both branches, configured gain ratio, and limiter behavior
  - Tighten pass criteria so it can actually catch regressions instead of passing anything louder than `-40 dB`

## Test Plan
- Static checks:
  - `bash -n ~/bin/signal-record.sh`
  - Validate help text and argument parsing for `--mic-mode` and `--mute-system-mic-during-recording`
- Deterministic audio checks:
  - Remote-only self-test must produce mean volume in the target window of `-32 dB` to `-22 dB`
  - Channel delta must be `<= 1 dB`
  - Mixed self-test must show both tones present with the configured remote-over-mic level difference and no clipping above the limiter target
- Regression checks using the existing March 4 samples:
  - Use the weak `signal-call-20260304-080449.m4a` and good baseline `call-20260304-080455.m4a` as calibration references
  - Tune default remote gain so the processed Signal-isolated path lands within about `3 dB` of the `record-call.sh` baseline mean loudness
- Live manual checks:
  - Signal unmuted + `--mic-mode auto`: your voice is present in the recording
  - Signal muted + `--mic-mode auto`: keyboard typing is absent from the recording
  - `--mic-mode off`: no local mic noise regardless of Signal mute state
  - `--mute-system-mic-during-recording`: source mute is restored correctly after exit and after `Ctrl+C`

## Assumptions and Defaults
- `record-call.sh` remains the loudness reference for "good" output.
- Default behavior after the fix is `--mic-mode auto`.
- Safe fallback for failed auto-detection is remote-only recording, not mic-on recording.
- Auto-follow is based on PulseAudio/PipeWire source-output state for the Signal client, not on brittle window-title or UI automation.
- If auto-follow proves unreliable in live testing, keep `auto` as best-effort with explicit fallback messaging rather than silently capturing the mic.
