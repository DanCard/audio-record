#!/bin/bash

# Record only Signal call audio (isolates from YouTube, games, etc.)
# Uses PipeWire pw-link to route Signal's ringrtc through a virtual sink

SPEAKER="alsa_output.pci-0000_c6_00.6.analog-stereo"
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"
SIGNAL_NODE="ringrtc"
VIRTUAL_SINK="signal_sink"

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

LOADED_EC=0
LOADED_SINK=0
REWIRED=0

cleanup() {
    echo -e "\n------------------------------------------------"
    echo "Cleaning up..."

    # Restore Signal audio back to main speakers
    if [ "$REWIRED" -eq 1 ]; then
        pw-link -d "${SIGNAL_NODE}:output_FL" "${VIRTUAL_SINK}:playback_FL" 2>/dev/null
        pw-link -d "${SIGNAL_NODE}:output_FR" "${VIRTUAL_SINK}:playback_FR" 2>/dev/null
        pw-link -d "${VIRTUAL_SINK}:monitor_FL" "${SPEAKER}:playback_FL" 2>/dev/null
        pw-link -d "${VIRTUAL_SINK}:monitor_FR" "${SPEAKER}:playback_FR" 2>/dev/null
        pw-link "${SIGNAL_NODE}:output_FL" "${SPEAKER}:playback_FL" 2>/dev/null
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
pw-link -d "${SIGNAL_NODE}:output_FL" "${SPEAKER}:playback_FL" 2>/dev/null
pw-link -d "${SIGNAL_NODE}:output_FR" "${SPEAKER}:playback_FR" 2>/dev/null

pw-link "${SIGNAL_NODE}:output_FL" "${VIRTUAL_SINK}:playback_FL"
pw-link "${SIGNAL_NODE}:output_FR" "${VIRTUAL_SINK}:playback_FR"

# Loopback so you still hear Signal
pw-link "${VIRTUAL_SINK}:monitor_FL" "${SPEAKER}:playback_FL"
pw-link "${VIRTUAL_SINK}:monitor_FR" "${SPEAKER}:playback_FR"
REWIRED=1
echo "Signal audio isolated (other apps unaffected)"

# --- Load echo cancellation for mic ---
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
ffmpeg -stats -y \
  -f pulse -i "${VIRTUAL_SINK}.monitor" \
  -f pulse -i "echocancel_source" \
  -filter_complex "[0:a]volume=6.0[remote];[1:a]volume=8.0[mic];[remote][mic]amix=inputs=2:duration=longest:normalize=0[mixed];[mixed]loudnorm=I=-16:TP=-1.5:LRA=11" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"
