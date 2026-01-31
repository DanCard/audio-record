#!/bin/bash

# VERSION 4: Use PulseAudio echo cancellation module
# This loads the echo cancel module and uses it for recording

MONITOR="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"

# Set filename (uses first argument if provided, else just timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

echo "------------------------------------------------"
echo "RECORDING STARTED (V4: PulseAudio Echo Cancel)"
echo "Output: $OUTFILE"
echo "------------------------------------------------"

# Check if echo cancel module is already loaded
if ! pactl list short modules | grep -q module-echo-cancel; then
    echo "Loading PulseAudio echo cancellation module..."
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

# Give PulseAudio a moment to set up
sleep 1

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# Use the echo-cancelled source
ffmpeg -stats -y \
  -f pulse -i "$MONITOR" \
  -f pulse -i "echocancel_source" \
  -filter_complex "[0:a][1:a]amix=inputs=2:duration=longest" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"

# Optionally unload the module when done
if [ "$LOADED_MODULE" -eq 1 ]; then
    echo "Unloading echo cancel module..."
    pactl unload-module module-echo-cancel 2>/dev/null || true
fi

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "------------------------------------------------"
