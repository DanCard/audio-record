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
# USAGE:
#   signal-record.sh [name]    # Start a Signal call first, then run this
#   signal-record.sh anti-drone-weekly
#   signal-record.sh --mic-mode off
#   signal-record.sh --self-test [name]
#   Press 'q' or Ctrl+C to stop recording
#
# REQUIRES: PipeWire, PulseAudio compatibility layer, ffmpeg
#   Signal must be in an active call (ringrtc node must exist)

# --- Hardware-specific device names (from `pactl list short sinks/sources`) ---
SPEAKER="alsa_output.pci-0000_c6_00.6.analog-stereo"          # Built-in speakers
ORIGINAL_MIC="alsa_input.usb-EMEET_HD_Webcam_eMeet_C950_A230803002402311-02.analog-stereo"  # USB webcam mic
SIGNAL_NODE="ringrtc"       # Signal's WebRTC audio output node name in PipeWire
VIRTUAL_SINK="signal_sink"  # Name for the virtual sink we create

# Tunable output gain for Signal-isolated recordings (override per run if needed):
SIGNAL_REMOTE_GAIN_DB="${SIGNAL_REMOTE_GAIN_DB:-22}"
SIGNAL_MIC_GAIN_DB="${SIGNAL_MIC_GAIN_DB:-0}"
# Self-test recording length in seconds (override per run if needed):
SIGNAL_SELF_TEST_SECONDS="${SIGNAL_SELF_TEST_SECONDS:-25}"
SIGNAL_MIC_MODE="${SIGNAL_MIC_MODE:-auto}"

usage() {
    cat <<EOF
Usage:
  $(basename "$0") [name]
  $(basename "$0") --self-test [name]
  $(basename "$0") --self-test --self-test-seconds N [name]

Options:
  --mic-mode auto|on|off             Set microphone capture mode (default: ${SIGNAL_MIC_MODE})
  --mute-system-mic-during-recording Mute hardware mic during the call
  --self-test                        Run deterministic test without a live Signal call
  --self-test-seconds N              Self-test duration in seconds (default: ${SIGNAL_SELF_TEST_SECONDS})
  -h, --help                         Show this help

Environment:
  SIGNAL_REMOTE_GAIN_DB    Remote gain in dB (default: ${SIGNAL_REMOTE_GAIN_DB})
  SIGNAL_MIC_GAIN_DB       Mic gain in dB (default: ${SIGNAL_MIC_GAIN_DB})
EOF
}

if [ "${INHIBIT_SLEEP_ACTIVE:-0}" != "1" ] && command -v inhibit-sleep >/dev/null 2>&1; then
    export INHIBIT_SLEEP_ACTIVE=1
    exec inhibit-sleep "$0" "$@"
fi

SELF_TEST=0
SELF_TEST_SECONDS="$SIGNAL_SELF_TEST_SECONDS"
MIC_MODE="$SIGNAL_MIC_MODE"
MUTE_MIC=0
NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --mic-mode)
            if [[ "$2" != "auto" && "$2" != "on" && "$2" != "off" ]]; then
                echo "ERROR: --mic-mode must be auto, on, or off."
                exit 1
            fi
            MIC_MODE="$2"
            shift 2
            ;;
        --mute-system-mic-during-recording)
            MUTE_MIC=1
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --self-test-seconds)
            if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "ERROR: --self-test-seconds requires an integer value."
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

ORIGINAL_MUTE_STATE=$(pactl get-source-mute "$ORIGINAL_MIC" 2>/dev/null | grep -i 'yes')
if [ "$MUTE_MIC" -eq 1 ]; then
    pactl set-source-mute "$ORIGINAL_MIC" 1 2>/dev/null
    echo "Hardware mic muted via --mute-system-mic-during-recording."
fi

# Undo all audio routing changes on exit (Ctrl+C, quit, or error)
cleanup() {
    echo -e "\n------------------------------------------------"
    echo "Cleaning up..."

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

    if [ "$MUTE_MIC" -eq 1 ]; then
        if [ -z "$ORIGINAL_MUTE_STATE" ]; then
            pactl set-source-mute "$ORIGINAL_MIC" 0 2>/dev/null
            echo "  Hardware mic unmuted."
        else
            echo "  Hardware mic was originally muted, left muted."
        fi
    fi

    echo "Recording saved to: $OUTFILE"
    echo "------------------------------------------------"
}

trap cleanup EXIT

# Mic mode auto-detection logic
FINAL_MIC_ON=1
if [ "$MIC_MODE" = "off" ]; then
    FINAL_MIC_ON=0
elif [ "$MIC_MODE" = "auto" ]; then
    # Look for Signal's mic capture stream
    if pactl list source-outputs | grep -qi 'ringrtc'; then
        FINAL_MIC_ON=1
        echo "MIC MODE AUTO: Mic stream found -> ON"
    else
        FINAL_MIC_ON=0
        echo "MIC MODE AUTO: Mic stream NOT found -> OFF"
        echo "Note: Falling back to safe remote-only to prevent keyboard leak."
    fi
else
    FINAL_MIC_ON=1
    echo "MIC MODE: ON"
fi

if [ "$FINAL_MIC_ON" -eq 1 ]; then
    MIX_FILTER="[0:a]pan=mono|c0=0.5*c0+0.5*c1,volume=${SIGNAL_REMOTE_GAIN_DB}dB[sig];[1:a]volume=${SIGNAL_MIC_GAIN_DB}dB[mic];[sig][mic]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95,pan=stereo|c0=c0|c1=c0"
else
    MIX_FILTER="[0:a]pan=mono|c0=0.5*c0+0.5*c1,volume=${SIGNAL_REMOTE_GAIN_DB}dB,alimiter=limit=0.95,pan=stereo|c0=c0|c1=c0"
fi

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

    loudness_ok=$(awk -v m="$mean" 'BEGIN {if (m >= -32.0 && m <= -22.0) print "yes"; else print "no"}')
    balance_ok=$(awk -v d="$balance_diff" 'BEGIN {if (d <= 1.0) print "yes"; else print "no"}')

    echo "------------------------------------------------"
    echo "SELF-TEST REPORT"
    echo "File: $OUTFILE"
    echo "Overall mean volume : ${mean} dB"
    echo "Overall max volume  : ${max} dB"
    echo "Channel mean (L/R)  : ${ch0_mean} dB / ${ch1_mean} dB"
    echo "Channel delta       : ${balance_diff} dB"

    if [ "$loudness_ok" = "yes" ]; then
        echo "Loudness check      : PASS (target mean -32 to -22 dB)"
    else
        echo "Loudness check      : FAIL (target mean -32 to -22 dB)"
    fi

    if [ "$balance_ok" = "yes" ]; then
        echo "Balance check       : PASS (target L/R delta <= 1 dB)"
    else
        echo "Balance check       : FAIL (target L/R delta <= 1 dB)"
    fi

    if [ "$loudness_ok" = "yes" ] && [ "$balance_ok" = "yes" ]; then
        echo "SELF-TEST RESULT    : PASS"
    else
        echo "SELF-TEST RESULT    : FAIL"
        echo "Tip: Check SIGNAL_REMOTE_GAIN_DB setting."
    fi
    echo "------------------------------------------------"
}

if [ "$SELF_TEST" -eq 1 ]; then
    echo "------------------------------------------------"
    echo "SELF-TEST STARTED (no Signal call needed)"
    echo "Output: $OUTFILE"
    echo "Duration: ${SELF_TEST_SECONDS}s"
    echo "------------------------------------------------"

    # Self-test inputs:
    #   input 0 = deterministic calibration tone (asymmetric left only, to verify L/R downmix)
    if [ "$FINAL_MIC_ON" -eq 1 ]; then
        ffmpeg -stats -y \
          -f lavfi -i "aevalsrc=0.01*sin(2*PI*997*t)|0:s=48000" \
          -f lavfi -i "aevalsrc=0.03*sin(2*PI*400*t)|0:s=48000" \
          -filter_complex "$MIX_FILTER" \
          -c:a aac -b:a 192k \
          -ac 2 \
          -t "$SELF_TEST_SECONDS" \
          "$OUTFILE"
    else
        ffmpeg -stats -y \
          -f lavfi -i "aevalsrc=0.01*sin(2*PI*997*t)|0:s=48000" \
          -filter_complex "$MIX_FILTER" \
          -c:a aac -b:a 192k \
          -ac 2 \
          -t "$SELF_TEST_SECONDS" \
          "$OUTFILE"
    fi

    print_self_test_report
    exit 0
fi

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

pw-link "${VIRTUAL_SINK}:monitor_FL" "${SPEAKER}:playback_FL"
pw-link "${VIRTUAL_SINK}:monitor_FR" "${SPEAKER}:playback_FR"
REWIRED=1
echo "Signal audio isolated (other apps unaffected)"

# --- Load echo cancellation for mic ---
if [ "$FINAL_MIC_ON" -eq 1 ]; then
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
fi

sleep 1

echo "Press 'q' or Ctrl+C to stop."
echo "------------------------------------------------"

# --- Record: Signal audio (virtual sink monitor) + your mic ---
if [ "$FINAL_MIC_ON" -eq 1 ]; then
    ffmpeg -stats -y \
      -f pulse -sample_rate 48000 -i "${VIRTUAL_SINK}.monitor" \
      -f pulse -sample_rate 48000 -i "echocancel_source" \
      -filter_complex "$MIX_FILTER" \
      -c:a aac -b:a 192k \
      -ac 2 \
      -t 02:30:00 \
      "$OUTFILE"
else
    ffmpeg -stats -y \
      -f pulse -sample_rate 48000 -i "${VIRTUAL_SINK}.monitor" \
      -filter_complex "$MIX_FILTER" \
      -c:a aac -b:a 192k \
      -ac 2 \
      -t 02:30:00 \
      "$OUTFILE"
fi
