# Fix signal-record.sh Audio Quality (Resolved)

## Context
As of March 1, 2026, `signal-record.sh` was still producing significantly lower quality audio compared to `record-call.sh`, despite previous attempts to fix it with complex filter chains and `dynaudnorm`.

## Problem Analysis
Comparing two recordings of the same Signal call made with both scripts:
- **signal-record.sh** (`signal-call-20260301-110309.m4a`): mean_volume: **-58.5 dB**, max_volume: -16.0 dB.
- **record-call.sh** (`call-20260301-110321.m4a`): mean_volume: **-29.3 dB**, max_volume: -6.4 dB.

The ~30 dB difference in mean volume pushed the Signal-isolated recording into the noise floor, resulting in poor quality. The use of `dynaudnorm` was introducing "pumping" artifacts and raising the noise floor without successfully normalizing the levels to a usable range.

## Implementation (v1.5)
The solution was to simplify the `ffmpeg` filter chain in `~/bin/signal-record.sh` to match the minimalist approach of `record-call.sh`, while keeping the app isolation logic.

### Filter Changes
Replaced the complex chain:
`[0:a]pan=mono|c0=c0,volume=6dB[signal];[1:a]pan=mono|c0=c0,volume=3dB[mic];[signal][mic]amix=inputs=2:duration=longest:weights=1 1:normalize=0,dynaudnorm=p=0.95:m=10:s=5,pan=stereo|c0=c0|c1=c0[out]`

With a simple, high-quality mix:
`[0:a][1:a]amix=inputs=2:duration=longest:normalize=0`

### Key Improvements
1. **Removed `dynaudnorm`**: Eliminated pumping artifacts and noise floor elevation.
2. **Removed redundant `pan` and `volume` filters**: Reduced processing stages that were degrading the signal.
3. **Retained `normalize=0`**: Ensures `amix` does not halve the volume of each input (the default behavior which causes 1/N attenuation).
4. **Matched `record-call.sh` strategy**: Since `record-call.sh` produces excellent results at ~-30 dB mean volume, matching its filter chain ensures consistent output.

## Verification
1. Run `signal-record.sh` during a Signal call.
2. Verify that mean volume is now in the -25 dB to -35 dB range.
3. Confirm absence of compression/normalization artifacts.
