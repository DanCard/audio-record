# Echo Reduction Experiments for Signal Recording

## Problem
Slight echo when recording Signal video meetings with `record-call.sh`.

## Possible Causes

1. **Acoustic feedback** - Microphone picking up speaker output physically
2. **PulseAudio loopback** - Monitor source may include mic audio being routed back
3. **amix mixing behavior** - Default settings can cause phase issues

## Experiments (Recommended Order)

### 1. PulseAudio Echo Cancellation (v4-echocancel.sh)
**Most likely to work** - Uses WebRTC's acoustic echo cancellation, specifically designed for voice calls.
```bash
pactl load-module module-echo-cancel source_name=echocancel_source sink_name=echocancel_sink source_master="$MIC" aec_method=webrtc
```
Then record from `echocancel_source` instead of the raw mic.

### 2. Noise Gate (v5-gate.sh)
Mutes mic when you're not speaking, preventing it from picking up speaker output.
```bash
-filter_complex "[1:a]agate=threshold=0.01:attack=5:release=50[mic];[0:a][mic]amix=inputs=2:duration=longest"
```

### 3. Combined Approach (v6-combo.sh)
Kitchen sink - all techniques together: volume reduction + highpass + noise gate.

### 4. Adjust Volumes (v1-volume.sh)
Simple fix if mic is just too hot. Reduces mic level to 70%.
```bash
-filter_complex "[0:a]volume=1.0[a0];[1:a]volume=0.7[a1];[a0][a1]amix=inputs=2:duration=longest"
```

### 5. Highpass Filter (v3-highpass.sh)
Cut low-frequency rumble and echo below 80Hz.
```bash
-filter_complex "[0:a][1:a]amix=inputs=2:duration=longest,highpass=f=80"
```

### 6. Use amerge Instead of amix (v2-amerge.sh)
Least likely to fix echo, but worth trying if others fail. Keeps channels more separate.
```bash
-filter_complex "[0:a][1:a]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3"
```

## Test Scripts

| Script | Description |
|--------|-------------|
| `record-call-v4-echocancel.sh` | PulseAudio WebRTC echo cancellation |
| `record-call-v5-gate.sh` | Noise gate mutes mic when not speaking |
| `record-call-v6-combo.sh` | Combined: volume + highpass + gate |
| `record-call-v1-volume.sh` | Reduces mic to 70% volume |
| `record-call-v3-highpass.sh` | Adds 80Hz highpass filter |
| `record-call-v2-amerge.sh` | Uses amerge instead of amix |

## Diagnostic Commands

Check current audio sources:
```bash
pactl list short sources
pactl list short sinks
```

Verify no audio loops exist in PulseAudio routing.

## Results

| Version | Date | Result |
|---------|------|--------|
| v4-echocancel | 2025-01-31 | ✓ Worked well |
| | | |
| | | |
