# CMIICollector — guided gesture elicitation

_Draft spec, 2026-08-19. Turns the app from three free-form study phases into a scheduled
gesture-elicitation instrument. Name and bundle id (`com.cmii.collector`) unchanged._

## 1. Purpose

Produce **labelled** wrist-IMU training data. The iPad cues a specific gesture at a specific
place and time; the watch records the movement. The app's job is to make the label
trustworthy and the timing precise. Everything below follows from that.

## 2. Three design rules

**The cue is the label; the classifier is a check.** The trial is labelled by what the app
*asked for*, not by what `GestureClassifier` decided. That sidesteps the vocabulary gaps
(double-tap currently emits two taps; drag vs scroll is separated only by velocity) and gives
something better: log the cued gesture, the classified gesture, and a `match` flag, so trials
where the participant did the wrong thing can be dropped rather than silently poisoning the
training set. With child participants this will not be rare.

**Gesture must never be fixed to a block.** If top-left is always "tap", gesture type is
confounded with screen location. At the wrist, reaching a far corner differs more — arm
extension, elevation, forearm rotation — than a tap differs from a double-tap in one spot. A
model trained on that learns where the hand went, not what it did. The schedule therefore
assigns gesture→block per trial, balanced so every gesture appears in every block equally
often. Position becomes a nuisance variable you have averaged over, and can be tested for
explicitly afterwards.

**Direction is part of the class.** Swipe-left and swipe-up are different movements at the
wrist. Left unspecified, "swipe" becomes a mixture whose within-class variance swamps the
between-person signal. Direction is scheduled and balanced like everything else.

## 3. Gesture vocabulary

| gesture | directions | target affordance | classifier label today |
|---|---|---|---|
| `tap` | — | animal image | `tap` |
| `double_tap` | — | animal image | two × `tap` (verification gap) |
| `long_press` | — | animal image | `long_press` |
| `swipe` | L, R, U, D | animal image, flick away | `swipe` (velocity-gated) |
| `drag` | L, R, U, D | animal image → target box in block | `scroll` or `swipe` (gap) |
| `scroll` | U, D | short scrollable strip in block | `scroll` |
| `pinch` | in, out | zoomable animal image | `pinch` |
| `rotate` | CW, CCW | rotatable animal image | `rotate` |

17 distinct (gesture, direction) conditions. Balanced across 4 blocks = **68 trials** per full
cycle; at ~4 s per trial plus a ~2 s gap that is **~7 minutes**. Feasible for adults, likely
at the edge for children — hence configurable repetitions and the ability to run a subset.

Note the two verification gaps (`double_tap`, `drag`). They do not block labelling, because
the cue is the label. Closing them later only improves the `match` check.

## 4. Trial lifecycle

```
  idle ─▶ ready ─▶ cue shown ─▶ touch down ─▶ touch up ─▶ scored ─▶ gap ─▶ next
          ▲                                                                │
          └────────────────────────────────────────────────────────────────┘
```

- **ready** — a quiet pre-cue window (default 800 ms). Gives a clean IMU baseline before each
  gesture, which matters for onset detection on the watch side.
- **cue shown** — one block highlights and shows its instruction. `cue_on_ms` is recorded.
- **timeout** — if nothing happens within `cue_timeout_ms`, the trial is marked `timeout` and
  the schedule moves on. Never block on a participant who did not understand.
- **scored** — cued vs classified compared, `match` written.
- **gap** — randomised `gap_min_ms..gap_max_ms` so trials do not blur together in the IMU
  stream and so the participant cannot fall into a rhythm.

One cue is active at a time. All four blocks stay visible (so the layout is stable and the
reach distances are comparable) but only the cued block is active.

## 5. Schedule JSON

Saved with the session so each dataset is self-describing, and loadable in the panel so a run
is reproducible.

```json
{
  "schedule_version": 1,
  "name": "pilot_full",
  "seed": 20260819,
  "blocks": {"rows": 2, "cols": 2},
  "assignment": "balanced_random",
  "repetitions": 2,
  "ready_ms": 800,
  "cue_timeout_ms": 6000,
  "gap_min_ms": 1500,
  "gap_max_ms": 3000,
  "picture_set": "animals_v1",
  "picture_assignment": "random_per_trial",
  "gestures": [
    {"type": "tap",        "enabled": true,  "directions": []},
    {"type": "double_tap", "enabled": true,  "directions": []},
    {"type": "long_press", "enabled": true,  "directions": []},
    {"type": "swipe",      "enabled": true,  "directions": ["L","R","U","D"]},
    {"type": "drag",       "enabled": true,  "directions": ["L","R","U","D"]},
    {"type": "scroll",     "enabled": true,  "directions": ["U","D"]},
    {"type": "pinch",      "enabled": true,  "directions": ["in","out"]},
    {"type": "rotate",     "enabled": true,  "directions": ["CW","CCW"]}
  ]
}
```

`seed` is the important field. The same seed across family members gives matched sequences for
within-design comparison; different seeds give independence. Either way the run is
reproducible, which a purely random schedule would not be.

`assignment`: `balanced_random` (each gesture in each block equally often, order shuffled),
`pure_random`, or `fixed` (diagnostic only — see rule 2).

## 6. Config panel

- gesture checkboxes + per-gesture direction toggles
- repetitions; live **trial count and estimated duration** (essential when the participant is a
  child — you need to know it is 7 minutes before you start, not after)
- ready / timeout / gap-min / gap-max
- assignment mode, seed (with a "new seed" button)
- picture set and whether pictures are re-assigned per trial
- save / load / duplicate named schedules

## 7. New outputs

Alongside the existing four CSVs, per session:

`<name>_trials.csv`
```
trial_idx,cue_on_ms,block_row,block_col,cued_gesture,cued_direction,picture_id,
  first_down_ms,last_up_ms,outcome,classified_gesture,match
```
`outcome` ∈ `completed` | `timeout` | `aborted`. `match` ∈ `1` | `0` | `` (blank where the
classifier has a known gap, so a missing check is never mistaken for a failed one).

`<name>_schedule.json` — the schedule as run, verbatim.

`<name>_session.json` — metadata:
```json
{"participant_id": "P03", "watch_wrist": "left", "interacting_hand": "right",
 "tablet_orientation": "landscape", "posture": "on_stand",
 "app_version": "...", "started_wall_ms": 0, "clock_sync": {...}}
```
Handedness and posture are not optional. Family members will differ systematically in all of
them, and without these fields sessions are not comparable — which is fatal for a
between-person identification task.

## 8. Clock alignment

`wall_ms` is iPad epoch ms; `kernel_ts` is `UITouch.timestamp` (monotonic since boot). The watch
has its own clock. The existing sync-anchor procedure in `EXPERIMENT_PROTOCOL.md` still applies
and its result belongs in `session.json`. Note the separate, already-documented trap: the iPad's
wall clock free-runs when it is off Wi-Fi (seconds of error within minutes) — keep it on Wi-Fi
for the whole session.

## 9. Code changes

| file | change |
|---|---|
| `Schedule.swift` | **new** — schedule model, JSON codable, seeded balanced generator |
| `TrialRunner.swift` | **new** — the state machine in §4, emits trial rows |
| `ContentView.swift` | replace the 3-phase picker with the config panel + 2×2 cue screen |
| `Recorder.swift` | add `_trials.csv`, `_schedule.json`, `_session.json` writers |
| `GestureClassifier.swift` | later: double-tap, and drag vs scroll by target-follow rather than velocity |
| `README.md` | rewrite; also correct the stale "PiP / foreground impossible" claim, which the syslog route has since disproved |

`TouchLogger.swift` and `BLEScanner.swift` are unchanged.

## 10. Open questions

1. **Repetitions per condition.** 2 gives 68 trials / ~7 min. How many sessions per person, and
   is one long session or several short ones better for the children?
2. **Pinch and rotate with one watch.** Both are two-finger; if performed one-handed the watch
   sees them, but they are harder to cue with a picture and slower. Keep in the main set, or
   split into an adults-only phase?
3. **Do we want a practice block** (uncued, unscored) before the real one, to reduce
   learning effects in the first trials?
4. **Scroll target.** A scrollable strip inside a 2×2 block is small. Does scroll deserve a
   full-screen phase instead?
