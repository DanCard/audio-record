# Findings & Decisions

## Requirements
- Fix weak volume in `~/bin/signal-record.sh` recordings.
- Use provided samples for comparison:
  - `comms/signal-call-20260304-080449.m4a` (too quiet)
  - `comms/call-20260304-080455.m4a` (good baseline)
- Review prior remediation attempts in `plans/` and avoid repeating ineffective fixes.

## Research Findings
- Prior plan documents (`plans/260228-...` and `plans/260301-...`) state a previous fix simplified filter chain to `amix=normalize=0` and removed `dynaudnorm`.
- Despite that prior “resolved” note, the user still reports weak volume in a newer sample from March 4, 2026.
- This indicates either:
  - runtime script differs from expected version,
  - gain loss is now occurring before/after mix stage,
  - or source capture levels differ in Signal-isolated path.
- Repo scripts are byte-identical with runtime scripts in `~/bin` (`cmp` returned identical for both `signal-record.sh` and `record-call.sh`).
- Measured current samples:
  - `signal-call-20260304-080449.m4a`: mean `-51.2 dB`, max `-16.8 dB`
  - `call-20260304-080455.m4a`: mean `-30.1 dB`, max `-6.3 dB`
  - Gap: ~`21 dB` mean, ~`10.5 dB` peak.
- Per-channel analysis of `signal-call` shows right channel is effectively near-silent:
  - ch0 mean `-48.2 dB`, max `-16.8 dB`
  - ch1 mean `-78.5 dB`, max `-56.7 dB`
- `record-call` sample is balanced stereo:
  - ch0 mean `-30.1 dB`, ch1 mean `-30.2 dB`.
- This confirms a channel-layout issue (near-mono-left output) in addition to low overall level.
- Dry-run filter testing on the weak sample with the chosen chain (`volume=12dB, alimiter, pan duplicate`) predicts:
  - mean `-35.7 dB`, max `-4.4 dB` (vs original mean `-51.2 dB`, max `-16.8 dB`)
  - significant improvement without reintroducing `dynaudnorm`.
- Updated script was synced to `~/bin/signal-record.sh` and syntax-checked there, so next real call run uses the fix directly.

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| Re-verify with objective loudness measurement on current samples | User already experienced repeated speculative fixes |
| Compare full script behavior, not only filter line | Prior “same filter” fix did not hold up in practice |
| Add deterministic gain + limiter and explicit mono->stereo handling | Raises level safely and removes near-silent right channel issue without reintroducing dynaudnorm pumping |
| Make gain tunable via `SIGNAL_MIX_GAIN_DB` (default 12 dB) | Enables quick adjustment per machine/call conditions without editing script again |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| Historical notes claim fixed, but user still sees defect | Treat as unresolved and re-open diagnosis from first principles |

## Resources
- `plans/260228-Fix-signal-record.sh-Audio-Quality.md`
- `plans/260301-Fix-signal-record.sh-Audio-Quality.md`
- `signal-record.sh`
- `record-call.sh`
- `comms/signal-call-20260304-080449.m4a`
- `comms/call-20260304-080455.m4a`

## Visual/Browser Findings
- None.
