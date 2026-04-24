# Audio Record

Record Signal (or other) video calls on Linux with both system audio and microphone, using PulseAudio echo cancellation to prevent feedback.

Canonical scripts:
- `~/bin/record-call.sh`
- `~/bin/signal-record.sh`

This repo keeps notes, plans, and supporting material. The runnable `signal-record.sh` now lives only in `~/bin/`.

## Requirements

- Linux with PulseAudio
- ffmpeg
- PulseAudio echo cancellation module (`module-echo-cancel`)

## Configuration

Edit `record-call.sh` and update these variables to match your hardware:

```bash
MONITOR="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"
MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"
```

To find your device names:

```bash
# List audio sources (microphones and monitors)
pactl list short sources

# List audio sinks (speakers/headphones)
pactl list short sinks
```

## Usage

```bash
# Record with default name (call-TIMESTAMP.m4a)
./record-call.sh

# Record with custom name (meeting-TIMESTAMP.m4a)
./record-call.sh meeting
```

Press `q` or `Ctrl+C` to stop recording.

## How It Works

The script:
1. Loads PulseAudio's WebRTC echo cancellation module
2. Captures system audio (what you hear) via the monitor source
3. Captures microphone input via the echo-cancelled source
4. Mixes both into a single AAC audio file

## Experiments

The `experiments/` folder contains alternative approaches tried for echo reduction:

| Script | Approach |
|--------|----------|
| v1-volume | Reduce mic volume |
| v2-amerge | Use amerge instead of amix |
| v3-highpass | Highpass filter at 80Hz |
| v4-echocancel | PulseAudio WebRTC echo cancellation ✓ |
| v5-gate | Noise gate on mic |
| v6-combo | Combined approach |

See `experiments/ECHO-EXPERIMENTS.md` for details.
