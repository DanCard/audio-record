#!/bin/bash

# VERSION 1: Adjusted volumes - reduce mic level to minimize echo
# Configuration - Specific to your hardware
MONITOR="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"
MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"

# Set filename (uses first argument if provided, else just timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

echo "------------------------------------------------"
echo "RECORDING STARTED (V1: Volume Adjusted)"
echo "Monitor: 100%, Mic: 70%"
echo "Output: $OUTFILE"
echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

ffmpeg -stats -y \
  -f pulse -i "$MONITOR" \
  -f pulse -i "$MIC" \
  -filter_complex "[0:a]volume=1.0[a0];[1:a]volume=0.7[a1];[a0][a1]amix=inputs=2:duration=longest" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "------------------------------------------------"
