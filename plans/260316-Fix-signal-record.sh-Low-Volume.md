# Fix signal-record.sh Low Volume

## Context
Recordings from today's anti-drone meeting confirm the persistent issue:
- `record-call.sh` output: **-27.5 dB** mean (good)
- `signal-record.sh` output: **-56.9 dB** mean (nearly inaudible, ~29 dB too quiet)

## Root Cause
`signal-record.sh` captures from `signal_sink.monitor` — a virtual null-sink that receives Signal's raw pre-volume audio. `record-call.sh` captures from the speaker monitor, which includes the system volume gain. The ~29 dB gap matches the system volume setting.

The script has `SIGNAL_REMOTE_GAIN_DB` (default 0) but **only applies it in the self-test path** (`build_self_test_filter`). The live recording path in `build_live_mix_filter()` and the mic-off ffmpeg command apply **zero gain** to the remote audio.

## Fix

### 1. Apply remote gain in the live recording path
**File:** `~/bin/signal-record.sh`

- Change `SIGNAL_REMOTE_GAIN_DB` default from `0` to `30` (matching the ~29 dB gap observed)
- Update `build_live_mix_filter()` to apply `SIGNAL_REMOTE_GAIN_DB` to `[0:a]` (the remote/virtual-sink-monitor input), same as `build_self_test_filter` already does
- Add a `volume` filter + `alimiter` to the mic-off recording path too
- Add `alimiter` after mixing to prevent clipping

### 2. Specific changes to `build_live_mix_filter()` (line 213)

Current (mic-on, no mic gain):
```
[0:a][1:a]amix=inputs=2:duration=longest:normalize=0
```

New (mic-on, with remote gain):
```
[0:a]volume={REMOTE_GAIN}dB[remote];[1:a]{optional mic gain}[mic];[remote][mic]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95
```

### 3. Add gain to mic-off ffmpeg path (line 547)

Current: raw capture with no filters.
New: add `-af "volume={REMOTE_GAIN}dB,alimiter=limit=0.95"`.

### 4. Change default gain
Line 34: `SIGNAL_REMOTE_GAIN_DB="${SIGNAL_REMOTE_GAIN_DB:-0}"` → `SIGNAL_REMOTE_GAIN_DB="${SIGNAL_REMOTE_GAIN_DB:-30}"`

## Files to Modify
- `~/bin/signal-record.sh` — lines 34, 213-223, 537-553

## Verification
1. `bash -n ~/bin/signal-record.sh` — syntax check
2. `signal-record.sh --self-test` — should still PASS
3. Compare volume: run both scripts on next call, verify signal-record output mean is within ~5 dB of record-call output
