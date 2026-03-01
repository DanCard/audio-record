#!/bin/bash

# signal-record.sh - Record Signal calls with app-level audio isolation
#
# WHAT THIS DOES:
#   Records a Signal call by capturing ONLY Signal's audio (not YouTube, games,
#   etc.) plus your microphone. Other apps' audio is unaffected.
#
# HOW IT WORKS:
#   1. Creates a virtual PipeWire sink (like a fake speaker)
#   2. Disconnects Signal (ringrtc) from your real speakers
#   3. Routes Signal audio into the virtual sink instead
#   4. Loops the virtual sink back to your speakers (so you still hear the call)
#   5. Records from the virtual sink's monitor (Signal only) + your mic
#   6. On exit, rewires Signal back to speakers and removes the virtual sink
#
#   Normal path:  Signal -> speakers
#   During recording:  Signal -> virtual_sink -> speakers (tapped for recording)
#
# VS record-call.sh:
#   record-call.sh captures ALL system audio (speaker monitor). If you play
#   music or a YouTube video during a call, it gets recorded too.
#   signal-record.sh isolates only Signal's audio stream.
#
# USAGE:
#   signal-record.sh [name]    # Start a Signal call first, then run this
#   signal-record.sh anti-drone-weekly
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PipeWire, PulseAudio compatibility layer, ffmpeg
#   Signal must be in an active call (ringrtc node must exist)
#
# VERSION HISTORY:
#   v1.0  2025-01-xx  Initial version - basic virtual sink + amix recording
#   v1.1  2025-01-xx  Added echo cancellation module (echocancel_source)
#   v1.2  2025-01-xx  Added loopback so user can still hear the call through speakers
#   v1.3  2025-02-xx  Attempted amix volume fix (still ~35 dB too quiet)
#   v1.4  2026-02-21  Fix audio level: recordings were ~35 dB quieter than record-call.sh
#                     - Added volume boost on inputs (+6dB signal, +3dB mic)
#                     - Set amix weights=1 1, normalize=0 to stop 1/N attenuation
#                     - Added dynaudnorm for consistent output levels
#                     - Set explicit sample_rate 48000 on pulse inputs
#                     Target: mean volume -25 to -30 dB (was -62 dB)
#   v1.5  2026-03-01  Simplified filter chain to fix poor quality/low volume.
#                     - Removed dynaudnorm and explicit pan/volume filters.
#                     - Reverted to simple amix=normalize=0 to match record-call.sh.

# --- Hardware-specific device names (from `pactl list short sinks/sources`) ---
SPEAKER="alsa_output.pci-0000_c6_00.6.analog-stereo"          # Built-in speakers
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"  # USB webcam mic
SIGNAL_NODE="ringrtc"       # Signal's WebRTC audio output node name in PipeWire
VIRTUAL_SINK="signal_sink"  # Name for the virtual sink we create

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-signal-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

# Track what we set up so cleanup only undoes what we did
LOADED_EC=0
LOADED_SINK=0
REWIRED=0

# Undo all audio routing changes on exit (Ctrl+C, quit, or error)
cleanup() {
    echo -e "\n------------------------------------------------"
    echo "Cleaning up..."

    # Restore Signal audio: disconnect from virtual sink, reconnect to speakers
    if [ "$REWIRED" -eq 1 ]; then
        pw-link -d "${SIGNAL_NODE}:output_FL" "${VIRTUAL_SINK}:playback_FL" 2>/dev/null  # -d = disconnect
        pw-link -d "${SIGNAL_NODE}:output_FR" "${VIRTUAL_SINK}:playback_FR" 2>/dev/null
        pw-link -d "${VIRTUAL_SINK}:monitor_FL" "${SPEAKER}:playback_FL" 2>/dev/null
        pw-link -d "${VIRTUAL_SINK}:monitor_FR" "${SPEAKER}:playback_FR" 2>/dev/null
        pw-link "${SIGNAL_NODE}:output_FL" "${SPEAKER}:playback_FL" 2>/dev/null  # reconnect directly
        pw-link "${SIGNAL_NODE}:output_FR" "${SPEAKER}:playback_FR" 2>/dev/null
        echo "  Signal audio restored to speakers"
    fi

    if [ "$LOADED_SINK" -eq 1 ]; then
        pactl unload-module module-null-sink 2>/dev/null || true
        echo "  Virtual sink removed"
    fi

    if [ "$LOADED_EC" -eq 1 ]; then
        pactl unload-module module-echo-cancel 2>/dev/null || true
        echo "  Echo cancel module unloaded"
    fi

    echo "Recording saved to: $OUTFILE"
    echo "------------------------------------------------"
}

trap cleanup EXIT

# --- Verify Signal is running ---
# pw-link -o lists all PipeWire output ports; ringrtc only exists during a call
if ! pw-link -o 2>/dev/null | grep -q "${SIGNAL_NODE}:output_FL"; then
    echo "ERROR: Signal call not detected (no ringrtc output found)."
    echo "Start a Signal call first, then run this script."
    exit 1
fi

echo "------------------------------------------------"
echo "RECORDING STARTED (Signal-only isolation)"
echo "Output: $OUTFILE"
echo "------------------------------------------------"

# --- Create virtual sink for Signal ---
# module-null-sink creates a fake audio device that exists only in software.
# It has a "playback" side (apps send audio to it) and a "monitor" side
# (we can record what was sent to it). This lets us tap Signal's audio.
if ! pactl list short sinks | grep -q "$VIRTUAL_SINK"; then
    pactl load-module module-null-sink \
        sink_name="$VIRTUAL_SINK" \
        sink_properties=device.description="Signal_Recording_Sink" >/dev/null
    LOADED_SINK=1
    echo "Virtual sink created"
else
    echo "Virtual sink already exists"
fi

# --- Rewire Signal through virtual sink ---
# pw-link connects/disconnects PipeWire audio ports (like patching cables)
#   -d = disconnect an existing link
#   FL/FR = front-left/front-right stereo channels

# Step 1: Disconnect Signal from real speakers
pw-link -d "${SIGNAL_NODE}:output_FL" "${SPEAKER}:playback_FL" 2>/dev/null
pw-link -d "${SIGNAL_NODE}:output_FR" "${SPEAKER}:playback_FR" 2>/dev/null

# Step 2: Route Signal into virtual sink (so we can record it)
pw-link "${SIGNAL_NODE}:output_FL" "${VIRTUAL_SINK}:playback_FL"
pw-link "${SIGNAL_NODE}:output_FR" "${VIRTUAL_SINK}:playback_FR"

# Step 3: Loop virtual sink's monitor back to speakers (so you still hear the call)
pw-link "${VIRTUAL_SINK}:monitor_FL" "${SPEAKER}:playback_FL"
pw-link "${VIRTUAL_SINK}:monitor_FR" "${SPEAKER}:playback_FR"
REWIRED=1
echo "Signal audio isolated (other apps unaffected)"

# --- Load echo cancellation for mic ---
# module-echo-cancel creates a new audio source that removes speaker bleed
# from the mic input. Without this, the remote caller's voice leaks back
# through your speakers into your mic, causing echo for them.
#   source_master  = the raw mic to process
#   aec_method     = webrtc (Google's echo cancellation algorithm)
#   aec_args:
#     analog_gain_control=0   = don't auto-adjust mic hardware gain
#     digital_gain_control=1  = do auto-adjust volume in software
#   use_master_format=1       = keep the mic's native sample rate/format
if ! pactl list short modules | grep -q module-echo-cancel; then
    pactl load-module module-echo-cancel \
        source_name=echocancel_source \
        sink_name=echocancel_sink \
        source_master="$ORIGINAL_MIC" \
        aec_method=webrtc \
        aec_args="analog_gain_control=0 digital_gain_control=1" \
        use_master_format=1 >/dev/null
    LOADED_EC=1
    echo "Echo cancellation loaded"
else
    echo "Echo cancel module already loaded"
fi

sleep 1

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Record: Signal audio (virtual sink monitor) + your mic ---
# ffmpeg flags:
#   -stats        = show progress (time, size) during recording
#   -y            = overwrite output file without asking
#   -f pulse      = use PulseAudio as input format (works with PipeWire)
#   -i "...monitor" = input 0: the virtual sink's monitor (Signal audio only)
#   -i "echocancel_source" = input 1: echo-cancelled mic
#   -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest"
#       [0:a]     = first input (Signal audio)
#       [1:a]     = second input (mic audio)
#       amix      = mix both streams into one
#       inputs=2  = two input streams
#       normalize=0 = prevent amix from halving volume (default 1/N)
#       duration=longest = keep recording until the longer stream ends
#   -c:a aac      = encode as AAC audio codec
#   -b:a 192k     = 192 kbps bitrate (good quality for voice)
#   -ac 2         = stereo output
#   -t 02:30:00   = max recording length 2.5 hours (safety limit)
ffmpeg -stats -y \
  -f pulse -sample_rate 48000 -i "${VIRTUAL_SINK}.monitor" \
  -f pulse -sample_rate 48000 -i "echocancel_source" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"
