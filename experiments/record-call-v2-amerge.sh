#!/bin/bash

# VERSION 2: Use amerge instead of amix - keeps channels more separate
# Configuration - Specific to your hardware
MONITOR="alsa_output.pci-0000_c6_00.6.analog-stereo.monitor"
MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"

# Set filename (uses first argument if provided, else just timestamp)
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NAME=${1:-call}
OUTFILE="${NAME}-${TIMESTAMP}.m4a"

echo "------------------------------------------------"
echo "RECORDING STARTED (V2: amerge instead of amix)"
echo "Output: $OUTFILE"
echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

ffmpeg -stats -y \
  -f pulse -i "$MONITOR" \
  -f pulse -i "$MIC" \
  -filter_complex "[0:a][1:a]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"

echo -e "\n------------------------------------------------"
echo "Recording saved to: $OUTFILE"
echo "------------------------------------------------"
