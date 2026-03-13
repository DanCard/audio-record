# Task Plan: Fix weak volume in signal-record.sh

## Goal
Make `signal-record.sh` produce Signal call recordings with volume comparable to `record-call.sh` for the same call conditions, then verify with the provided sample files.

## Current Phase
Phase 4

## Phases
### Phase 1: Requirements & Discovery
- [x] Understand user intent
- [x] Identify constraints and requirements
- [x] Document findings in findings.md
- **Status:** complete

### Phase 2: Root-Cause Analysis
- [x] Inspect `signal-record.sh` vs `record-call.sh` audio paths and FFmpeg settings
- [x] Measure loudness metrics on provided sample files
- [x] Identify likely source(s) of large gain loss
- **Status:** complete

### Phase 3: Implementation
- [x] Patch script logic responsible for weak output
- [x] Keep existing Signal-isolation behavior intact
- [x] Add safe defaults/guardrails if needed
- **Status:** complete

### Phase 4: Testing & Verification
- [x] Validate script syntax
- [x] Re-run loudness comparison checks for before/after assumptions
- [x] Document verification in progress.md
- [ ] Validate with a new live Signal call recording
- **Status:** in_progress

### Phase 5: Delivery
- [ ] Summarize root cause and fix clearly
- [ ] Provide exact changed file references
- [ ] Provide practical next-step verification command for user
- **Status:** pending

## Key Questions
1. Is weak volume caused by FFmpeg filter chain, input source gain, or both?
2. Is `signal-record.sh` in repo the same behavior path as `~/bin/signal-record.sh` that user runs?
3. Can we make gain adaptation deterministic enough without reintroducing clipping/pumping artifacts?

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| Use planning-with-files workflow for this task | Multi-step debugging with prior history and repeated failed attempts |
| Start by comparing provided sample loudness metrics | Objective measurement prevents guessing and repeated failed fixes |
| Address channel layout and gain directly in FFmpeg filter | Current sample has nearly silent right channel and large level gap |

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|
|       | 1       |            |

## Notes
- Do not regress Signal app-isolation behavior while fixing output level.
- Prefer minimal, measurable changes over heavy processing chains.
