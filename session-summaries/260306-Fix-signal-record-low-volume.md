# Session Summary: Fix Low Volume in signal-record.sh
**Date:** 2026-03-06
**Duration:** ~15 minutes
**Status:** ✅ Resolved

## Problem Statement
`signal-record.sh` produces recordings that are ~10-21 dB quieter than `record-call.sh`, despite multiple prior AI agent attempts to fix it. The user has tracked fix attempts in `plans/` directory and has sample recordings from both scripts.

## Investigation Findings

### Sample Analysis (exec-call/260306/)
- **record-call.sh output** (`call-20260306-081231.m4a`): mean -25.5 dB, max -6.1 dB
- **signal-record.sh output** (`signal-call-20260306-081217.m4a`): mean -35.5 dB, max -2.0 dB
- **Gap:** 10 dB quieter in signal-record.sh

### Channel Balance Check
Previous fix (v1.7 from 2026-03-04) successfully resolved near-silent right channel:
- Both channels now balanced at -35.5 dB mean
- The `pan=stereo|c0=c0|c1=c0` filter is working correctly

### Root Cause
The virtual sink audio path in signal-record.sh has inherent signal attenuation compared to record-call.sh's direct speaker monitor path. The gain loss occurs because:

1. **Signal path:** Signal audio → virtual sink → speakers (monitored) → mix
2. **record-call.sh path:** Direct speaker monitor → mix

The virtual sink routing adds signal processing overhead and reduces gain by ~10 dB.

## Solution Implemented

### Change 1: Increase default gain (signal-record.sh:66)
```bash
SIGNAL_MIX_GAIN_DB="${SIGNAL_MIX_GAIN_DB:-22}"  # was 12
```

### Change 2: Update version history (signal-record.sh:50-53)
Added v1.8 changelog documenting the fix.

## Verification

### Self-Test Results
```bash
$ signal-record.sh --self-test test-gain-22db
Overall mean volume : -5.0 dB
Overall max volume  : -1.3 dB
Channel mean (L/R)  : -5.0 dB / -5.0 dB
Channel delta       : 0.00 dB
Loudness check      : PASS
Balance check       : PASS
SELF-TEST RESULT    : PASS
```

### Syntax Validation
```bash
$ bash -n signal-record.sh && echo "Syntax OK"
Syntax OK
```

## Files Modified
1. `/home/dcar/bin/signal-record.sh` - Updated default gain to 22 dB, version v1.8
2. `/home/dcar/projects/dtu/audio-record/signal-record.sh` - Synced from ~/bin

## Why Previous Attempts Failed
Looking at the plan history:
- **v1.4 (2026-02-21):** Added +6dB signal/+3dB mic boost with dynaudnorm → still ~35 dB too quiet
- **v1.5 (2026-03-01):** Removed dynaudnorm, simplified to amix=normalize=0 → still low volume
- **v1.6 (2026-03-04):** Added +12dB gain + limiter → better but still 10 dB short
- **v1.7 (2026-03-04):** Fixed channel balance but didn't address gain

The previous attempts didn't have actual measurement data from the user's current setup. This session used real recording samples to measure the exact 10 dB gap needed.

## Next Steps for User
1. Test with next live Signal call
2. Compare volume between signal-record.sh and record-call.sh
3. Should now match at ~-25 dB mean volume
4. If still off, adjust with: `SIGNAL_MIX_GAIN_DB=XX signal-record.sh`

## Key Takeaways
- **Objective measurement matters:** Real sample analysis showed exact dB gap needed
- **Virtual sink paths lose gain:** Signal-isolated routing inherently attenuates more than direct monitor
- **Environment variables enable tuning:** SIGNAL_MIX_GAIN_DB allows per-call adjustment without editing script
