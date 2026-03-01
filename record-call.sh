#!/bin/bash

# record-call.sh - Record ALL system audio + mic (simple, works with any app)
#
# WHAT THIS DOES:
#   Records everything playing through your speakers (all apps) plus your
#   microphone. Simple and reliable - works with Signal, Zoom, Teams, etc.
#
# HOW IT WORKS:
#   1. Taps the speaker's "monitor" (a loopback of everything sent to speakers)
#   2. Captures your mic with echo cancellation (removes speaker bleed)
#   3. Mixes both into a single stereo AAC file
#
# VS signal-record.sh:
#   signal-record.sh isolates only Signal's audio (other apps excluded).
#   record-call.sh captures ALL system audio. Simpler, but if you play
#   music or a video during the call, it gets recorded too.
#
# USAGE:
#   record-call.sh [name]
#   record-call.sh drone-tech-weekly
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PulseAudio (or PipeWire with PulseAudio compat), ffmpeg

# --- Hardware-specific device names (from `pactl list short sinks/sources`) ---
# The ".monitor" suffix taps everything playing through the speakers
MONITOR="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"  # Speaker loopback
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"  # USB webcam mic

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

echo "------------------------------------------------"
echo "RECORDING STARTED (all system audio + mic)"
echo "Output: $OUTFILE"
echo "------------------------------------------------"

# --- Load echo cancellation for mic ---
# module-echo-cancel creates a new audio source that removes speaker bleed
# from the mic input. Without this, remote callers' voices leak back through
# your speakers into your mic, causing echo.
#   source_name    = name of the new echo-cancelled source we create
#   sink_name      = companion sink (required by the module, not used directly)
#   source_master  = the raw mic to process
#   aec_method     = webrtc (Google's echo cancellation algorithm)
#   aec_args:
#     analog_gain_control=0   = don't auto-adjust mic hardware gain
#     digital_gain_control=1  = do auto-adjust volume in software
#   use_master_format=1       = keep the mic's native sample rate/format
if ! pactl list short modules | grep -q module-echo-cancel; then
    echo "Loading echo cancellation module..."
    MODULE_ID=$(pactl load-module module-echo-cancel \
        source_name=echocancel_source \
        sink_name=echocancel_sink \
        source_master="$ORIGINAL_MIC" \
        aec_method=webrtc \
        aec_args="analog_gain_control=0 digital_gain_control=1" \
        use_master_format=1)
    echo "Module loaded with ID: $MODULE_ID"
    LOADED_MODULE=1
else
    echo "Echo cancel module already loaded"
    LOADED_MODULE=0
fi

sleep 1  # Give PulseAudio a moment to initialize the new source

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Record: all system audio + echo-cancelled mic ---
# ffmpeg flags:
#   -stats        = show progress (time, size) during recording
#   -y            = overwrite output file without asking
#   -f pulse      = use PulseAudio as input format (works with PipeWire)
#   -i "$MONITOR" = input 0: speaker monitor (ALL system audio)
#   -i "echocancel_source" = input 1: echo-cancelled mic
#   -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest"
#       [0:a]     = first input (system audio)
#       [1:a]     = second input (mic audio)
#       amix      = mix both streams into one
#       inputs=2  = two input streams
#       duration=longest = keep recording until the longer stream ends
#   -c:a aac      = encode as AAC audio codec
#   -b:a 192k     = 192 kbps bitrate (good quality for voice)
#   -ac 2         = stereo output
#   -t 02:30:00   = max recording length 2.5 hours (safety limit)
ffmpeg -stats -y \
  -f pulse -i "$MONITOR" \
  -f pulse -i "echocancel_source" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"

# Clean up: unload the echo cancel module if we loaded it
if [ "$LOADED_MODULE" -eq 1 ]; then
    echo "Unloading echo cancel module..."
    pactl unload-module module-echo-cancel 2>/dev/null || true
fi

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "------------------------------------------------"
