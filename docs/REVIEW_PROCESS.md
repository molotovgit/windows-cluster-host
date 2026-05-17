# Code Review Process

> Every code change to this repo is reviewed by an independent Claude subagent before merge.

## Workflow

```
1. Author writes/modifies code on a feature branch
        ↓
2. Author runs local self-tests (lint, syntax, unit)
        ↓
3. Author invokes the reviewer subagent with REVIEW_PROMPT.md + the file(s) under review
        ↓
4. Reviewer returns strict JSON verdict per the rubric
        ↓
5. IF verdict == "APPROVE" AND no critical_blockers:
     → Author creates PR
     → Author merges PR
        ↓
   IF "REJECT":
     → Author applies every item from required_fixes
     → Goes back to step 2
```

## The review prompt

`REVIEW_PROMPT.md` at the repo root is the canonical reviewer brief. It contains:

- The reviewer's role and authority
- Project context
- 10-dimension weighted scoring rubric (threshold = 85)
- Critical safety blockers (auto-reject regardless of score)
- PowerShell-specific checks
- Hyper-V / Windows-setup-specific checks
- Required JSON output format

## What counts as a "PASS"

The reviewer returns JSON with `verdict: "APPROVE"` only if **both**:

- `total_score` ≥ 85 (weighted sum of all 10 dimensions)
- `critical_blockers` array is empty

Anything else is **REJECT** and the author must apply every item in `required_fixes`.

## What counts as a critical blocker

See `REVIEW_PROMPT.md` § "CRITICAL SAFETY BLOCKERS" for the canonical list. Examples:

- Destructive operations without user-data protection
- Hardcoded credentials in source
- Empty `catch {}` blocks
- Network downloads without verification
- No reboot resumption for multi-stage operations

## How to invoke the review (for the author)

The author Claude uses its `Agent` tool with `subagent_type: "general-purpose"`. The subagent:

- Reads `REVIEW_PROMPT.md` from disk
- Reads the file(s) under review from disk
- Returns JSON only (no markdown wrapper, no preamble)

## Iteration

If the first review returns REJECT, the author applies the fixes and re-submits. The re-review prompt instructs the reviewer to **confirm every previous required_fix was addressed** before approving.

## Why this exists

PowerShell scripts that touch BIOS-adjacent features, install services, and manage Hyper-V can easily brick a PC or destroy user data. A second independent pair of eyes on every change catches what the author missed. The rubric is intentionally strict — the cost of a "lenient pass" that breaks production is much higher than the cost of one extra review cycle.
