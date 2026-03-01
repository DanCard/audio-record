# Fix signal-record.sh Audio Quality

## Context
`record-call.sh` produces much better call audio than `signal-record.sh` despite both using AAC 192kbps. The difference is in the ffmpeg filter chain — signal-record.sh has an overly complex processing pipeline that degrades quality while record-call.sh uses a simple amix.

## Problem
The signal-record.sh filter chain has 7 processing stages that hurt quality:
1. `pan=mono` on both inputs (unnecessary)
2. `volume=6dB` / `volume=3dB` boosts (blunt fix for a solved problem)
3. `amix` with `normalize=0` (this alone fixes the volume halving issue)
4. `dynaudnorm=p=0.95:m=10:s=5` — **primary offender**: 10ms frame length causes pumping artifacts, raises noise floor, kills natural dynamics
5. `pan=stereo` back (unnecessary with `-ac 2`)

## Plan

### Simplify the ffmpeg filter_complex in signal-record.sh

**File:** `/home/dcar/bin/signal-record.sh` (lines ~187-195)

Replace the current complex filter:
```
[0:a]pan=mono|c0=c0,volume=6dB[signal];[1:a]pan=mono|c0=c0,volume=3dB[mic];[signal][mic]amix=inputs=2:duration=longest:weights=1 1:normalize=0,dynaudnorm=p=0.95:m=10:s=5,pan=stereo|c0=c0|c1=c0[out]
```

With a simple filter matching record-call.sh's approach:
```
[0:a][1:a]amix=inputs=2:duration=longest:normalize=0
```

Also remove `-map "[out]"` since the named output is no longer used.

Keep everything else (virtual sink, PipeWire rewiring, echo cancellation) — app isolation is preserved.

## Verification
1. Run `signal-record.sh` during a test Signal call
2. Compare audio quality with a `record-call.sh` recording of the same call
3. Check volume levels are acceptable without the boosts (normalize=0 prevents halving)
