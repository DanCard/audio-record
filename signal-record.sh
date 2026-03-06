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
#   signal-record.sh --self-test [name]
#   signal-record.sh --self-test --self-test-seconds 20
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
#   v1.6  2026-03-04  Fix weak output + channel imbalance in Signal-isolated path.
#                     - Force balanced stereo by duplicating the mixed left channel.
#                     - Add controlled post-mix gain (default +12 dB, env overridable).
#                     - Add limiter to reduce clipping risk after gain.
#   v1.7  2026-03-04  Add deterministic self-test mode for no-meeting validation.
#                     - `--self-test` generates calibration audio (no Signal call needed).
#                     - Runs through same mix/filter/encoder chain.
#                     - Prints PASS/FAIL for loudness and channel balance.
#   v1.8  2026-03-06  Fix low volume to match record-call.sh levels.
#                     - Increased default gain from 12 dB to 22 dB based on actual measurements.
#                     - Signal recordings now ~-25 dB mean (same as record-call.sh).

# --- Hardware-specific device names (from `pactl list short sinks/sources`) ---
SPEAKER="alsa_output.pci-0000_c6_00.6.analog-stereo"          # Built-in speakers
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"  # USB webcam mic
SIGNAL_NODE="ringrtc"       # Signal's WebRTC audio output node name in PipeWire
VIRTUAL_SINK="signal_sink"  # Name for the virtual sink we create

# Tunable output gain for Signal-isolated recordings (override per run if needed):
#   SIGNAL_MIX_GAIN_DB=10 signal-record.sh
SIGNAL_MIX_GAIN_DB="${SIGNAL_MIX_GAIN_DB:-22}"
# Self-test recording length in seconds (override per run if needed):
#   SIGNAL_SELF_TEST_SECONDS=30 signal-record.sh --self-test
SIGNAL_SELF_TEST_SECONDS="${SIGNAL_SELF_TEST_SECONDS:-25}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [name]
  $(basename "$0") --self-test [name]
  $(basename "$0") --self-test --self-test-seconds N [name]

Options:
  --self-test              Run deterministic test without a live Signal call
  --self-test-seconds N    Self-test duration in seconds (default: ${SIGNAL_SELF_TEST_SECONDS})
  -h, --help               Show this help

Environment:
  SIGNAL_MIX_GAIN_DB       Post-mix gain in dB (default: ${SIGNAL_MIX_GAIN_DB})
  SIGNAL_SELF_TEST_SECONDS Default self-test duration
EOF
}

SELF_TEST=0
SELF_TEST_SECONDS="$SIGNAL_SELF_TEST_SECONDS"
NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --self-test-seconds)
            if [ -z "${2:-}" ]; then
                echo "ERROR: --self-test-seconds requires a value."
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --self-test-seconds must be an integer."
                exit 1
            fi
            SELF_TEST_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [ -n "$NAME" ]; then
                echo "ERROR: Only one optional recording name is supported."
                usage
                exit 1
            fi
            NAME="$1"
            shift
            ;;
    esac
done

if [ -z "$NAME" ]; then
    if [ "$SELF_TEST" -eq 1 ]; then
        NAME="signal-selftest"
    else
        NAME="signal-call"
    fi
fi

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
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

print_self_test_report() {
    local mean max ch0_mean ch1_mean balance_diff
    local loudness_ok balance_ok
    local num_re='^-?[0-9]+([.][0-9]+)?$'

    mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af volumedetect -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    max=$(ffmpeg -hide_banner -i "$OUTFILE" -af volumedetect -f null - 2>&1 | awk -F': ' '/max_volume/ {print $2}' | awk '{print $1}' | head -n1)
    ch0_mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af "pan=mono|c0=c0,volumedetect" -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    ch1_mean=$(ffmpeg -hide_banner -i "$OUTFILE" -af "pan=mono|c0=c1,volumedetect" -f null - 2>&1 | awk -F': ' '/mean_volume/ {print $2}' | awk '{print $1}' | head -n1)
    if ! [[ "$mean" =~ $num_re ]] || ! [[ "$max" =~ $num_re ]] || ! [[ "$ch0_mean" =~ $num_re ]] || ! [[ "$ch1_mean" =~ $num_re ]]; then
        echo "------------------------------------------------"
        echo "SELF-TEST REPORT"
        echo "File: $OUTFILE"
        echo "SELF-TEST RESULT    : FAIL (unable to parse loudness metrics)"
        echo "------------------------------------------------"
        return 1
    fi

    balance_diff=$(awk -v a="$ch0_mean" -v b="$ch1_mean" 'BEGIN {d=a-b; if (d<0) d=-d; printf "%.2f", d}')

    loudness_ok=$(awk -v m="$mean" 'BEGIN {if (m >= -40.0) print "yes"; else print "no"}')
    balance_ok=$(awk -v d="$balance_diff" 'BEGIN {if (d <= 3.0) print "yes"; else print "no"}')

    echo "------------------------------------------------"
    echo "SELF-TEST REPORT"
    echo "File: $OUTFILE"
    echo "Overall mean volume : ${mean} dB"
    echo "Overall max volume  : ${max} dB"
    echo "Channel mean (L/R)  : ${ch0_mean} dB / ${ch1_mean} dB"
    echo "Channel delta       : ${balance_diff} dB"

    if [ "$loudness_ok" = "yes" ]; then
        echo "Loudness check      : PASS (target mean >= -40 dB)"
    else
        echo "Loudness check      : FAIL (target mean >= -40 dB)"
    fi

    if [ "$balance_ok" = "yes" ]; then
        echo "Balance check       : PASS (target L/R delta <= 3 dB)"
    else
        echo "Balance check       : FAIL (target L/R delta <= 3 dB)"
    fi

    if [ "$loudness_ok" = "yes" ] && [ "$balance_ok" = "yes" ]; then
        echo "SELF-TEST RESULT    : PASS"
    else
        echo "SELF-TEST RESULT    : FAIL"
        echo "Tip: try SIGNAL_MIX_GAIN_DB=14 for another run if loudness failed."
    fi
    echo "------------------------------------------------"
}

MIX_FILTER="[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,volume=${SIGNAL_MIX_GAIN_DB}dB,alimiter=limit=0.95,pan=stereo|c0=c0|c1=c0"

if [ "$SELF_TEST" -eq 1 ]; then
    echo "------------------------------------------------"
    echo "SELF-TEST STARTED (no Signal call needed)"
    echo "Output: $OUTFILE"
    echo "Duration: ${SELF_TEST_SECONDS}s"
    echo "------------------------------------------------"

    # Self-test inputs:
    #   input 0 = deterministic calibration tone (left only, to verify L/R fix)
    #   input 1 = silence (acts as mic path placeholder)
    ffmpeg -stats -y \
      -f lavfi -i "aevalsrc=0.06*sin(2*PI*997*t)|0:s=48000" \
      -f lavfi -i "anullsrc=r=48000:cl=mono" \
      -filter_complex "$MIX_FILTER" \
      -c:a aac -b:a 192k \
      -ac 2 \
      -t "$SELF_TEST_SECONDS" \
      "$OUTFILE"

    print_self_test_report
    exit 0
fi

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
ffmpeg -stats -y \
  -f pulse -sample_rate 48000 -i "${VIRTUAL_SINK}.monitor" \
  -f pulse -sample_rate 48000 -i "echocancel_source" \
  -filter_complex "$MIX_FILTER" \
  -c:a aac -b:a 192k \
  -ac 2 \
  -t 02:30:00 \
  "$OUTFILE"
