# PSET / step data research

Findings only; no code changed. Investigated on upstream master (v1.9.1).

## Where step data lives

`step.data` in the script's data dir (`sequencer.lua:9`) holds **all** step
data: 50 patterns x 7 tracks x 32 steps, as newline-separated integers.

There is exactly **one** of these files. It is not per-PSET, and the PSET
files (`cyrene-01.pset` etc.) contain only params -- the user's observation
is correct.

## When it is read and written

| | call site | when |
|---|---|---|
| write | `cleanup()` -> `save_patterns()` (`cyrene.lua:262`) | script **exit** only |
| read | `Sequencer:initialize()` -> `load_patterns()` (`sequencer.lua:340`) | script **start** only |

There is no `params.action_read` / `action_write` hook anywhere in the
codebase, so loading or saving a PSET does not touch step data at all.

## Why loading a PSET appears to reset tracks 1-3

`set_grids_xy` is called on **every tick** (`sequencer.lua:626`). It
short-circuits only while Pattern X, Pattern Y and the three euclidean
flags all match the cached values. A PSET load changes those params, the
next tick sees the mismatch, and the drum map rewrites **every step** of
tracks 1-3 (`sequencer.lua:493`).

So the sequence the user reported:

1. Load PSET 1 -> tick rewrites tracks 1-3 from the drum map
2. Clear tracks 1-3 by hand
3. Save PSET 1 -> writes params only; the cleared steps go nowhere
4. Load PSET 2 -> X/Y differ, tick rewrites tracks 1-3
5. Load PSET 1 -> X/Y differ again, tick rewrites tracks 1-3

The cleared steps were never persisted, and would have been overwritten
even if they had been.

## Why the grid looks "completely filled"

The drum map writes a probability 0-255 to every step of tracks 1-3, and
the grid lights any **nonzero** value (`ui/grid.lua:164`). Because each
written value is a crossfade of four map nodes, a zero only survives when
all four nodes are zero, which is rare.

Measured directly from `grids_patterns.lua` at pattern length 16:

| Pattern X,Y | steps nonzero (of 48) | |
|---|---|---|
| 0,0 | 35 | 73% |
| 64,64 | 35 | 73% |
| 128,128 | 44 | 92% |
| 192,192 | 48 | **100%** |
| 255,255 | 41 | 85% |
| 200,100 | 48 | **100%** |

Average **89%**. So "all steps become filled" is the drum map behaving
normally; the grid is showing probability, not audible hits. Density then
gates which of those actually fire, so it sounds far sparser than it looks.

## Summary

Three distinct issues, one root cause each:

1. **Step data is global, not per-PSET.** One `step.data` for all 50 PSETs.
2. **Step data is only persisted on script exit.** Saving a PSET does not
   save steps; quitting without a clean exit loses them.
3. **Tracks 1-3 are owned by the drum map.** Hand edits there survive only
   until the next X/Y change, which a PSET load reliably causes.

## Possible directions (not implemented)

- Hook `params.action_write` / `action_read` to save and load a per-PSET
  step file (`step-01.data`), falling back to `step.data` when absent.
- Give tracks 1-3 a per-track "manual" flag that suppresses the drum map,
  so hand-edited drum patterns survive an X/Y change.
- Save step data on PSET save as well as on exit, so a crash or power cut
  does not discard the session.

The first two are user-visible behaviour changes and worth agreeing before
building.
