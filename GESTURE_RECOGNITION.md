# Gesture recognition

How Glogger decides, for a single stroke on the card board, whether it was a
tap, a double tap, a press-and-hold, a flick or a drag.

This is the reference for that decision. It is written against the code as it
stands, including the places where the two platforms currently disagree — those
are listed in "Divergences" at the end rather than quietly smoothed over.

## 0. Scope: this is user experience, not measurement

**Everything in this document exists so the tablet can react to the participant.
None of it collects the study's data.**

`Sensors.kt` and `MotionLogger.swift` contain no reference to `phase`, `runner`,
`gesture` or `trial`. The accelerometer, gyroscope, magnetometer and BLE loggers
run on their own timers from the moment recording starts. Delete every
classifier in this document and `_imu_accel.csv`, `_imu_gyro.csv`,
`_imu_mag.csv` and `_ble.csv` come out identical.

The consequence is worth stating plainly, because it is easy to read a threshold
like `flingVel = 420` and assume it is a measurement parameter. It is not. Get
the swipe/scroll split wrong and not one sample of inertial or radio data
changes. What changes is whether the card does what the participant expected.

That still matters, for a reason that runs the other way: a participant whose
gesture produced no response repeats it, and that trial's sensor window then
contains two movements instead of one. Reaction quality is how you get one clean
gesture per window. It is not how you get the window.

Two things in here are **not** covered by the above, and are data:

1. **Stroke boundaries.** `firstDownMs` and `lastUpMs` in `_trials.csv` come out
   of `StrokeAssembler` — the same file as the classifier — and that window is
   what slices the watch's IMU stream for a trial. Boundary detection, not
   classification, but it shares the pipeline.

2. **The verdict, if it is ever used to filter.** `match` in `_trials.csv`
   decides nothing on its own. But an analysis that keeps only matching trials
   has let the scorer choose which sensor segments enter the dataset — and the
   scorer currently disagrees between platforms (see Divergences). If trials are
   never filtered on `match`, those divergences are cosmetic.

**The cue is the label.** The play says which gesture was asked for; the
classifier only verifies. iOS states this on the scorer itself: *"Scoring
(verification only — the cue is the label)."*

---

## 1. Three layers, three answers

The word "gesture" means three different things in this codebase, decided at
different moments, by different code, and written to different files. Confusing
them is the source of most of the bugs we have found.

| Layer | Question | Decided by | Written to |
|---|---|---|---|
| **1. Board response** | What should the card do, right now? | Platform gesture recognisers on the deck view | `_deck.csv` (`flip`, `peek`, `dropped`, …) |
| **2. Stroke label** | What shape was this stroke? | `GestureClassifier` (Kotlin / Swift) | `_gestures.csv` (`type` column) |
| **3. Trial verdict** | Did they do the cued gesture? | `TrialRunner` scoring | `_trials.csv` (`observed`, `match`) |

Layer 1 runs **during** the gesture and must commit before the finger lifts —
that is what makes the card respond. Layer 2 runs **on release**, from the
complete stroke. Layer 3 runs when the scene resolves, over all strokes
collected in that scene.

Layer 2 is the scientific record. Layer 1 exists so the participant gets
feedback and so the board has app-level ground truth independent of the
classifier. **They are allowed to disagree**, and when they do, layer 2 wins for
analysis.

---

## 2. Quantities

Measured from one stroke: first finger down to last finger up.

| Symbol | Meaning |
|---|---|
| `d` | duration, last-up minus first-down (ms) |
| `disp` | straight-line displacement, first point to last |
| `path` | accumulated path length |
| `meanV` | `path / d` |
| `nf` | maximum simultaneous fingers |
| `taps` | strokes classified `tap` within the scene |

## 3. Thresholds

### Layer 2 — `GestureClassifier`

Identical logic in `GestureClassifier.kt` and `GestureClassifier.swift`.

| Name | Value | Unit |
|---|---|---|
| `longPressMs` | 500 | ms |
| `moveDist` | 10 | points |
| `flingVel` | 420 | points/s |
| `pinchDelta` | 20 | points |
| `rotateDeg` | 15 | degrees |

iOS reports touches in **points**; Android in **pixels**. Android therefore
scales the three distance/velocity thresholds by display density
(`GestureThresholds.scaled`), so a 2x tablet compares against 840 px/s rather
than 420. The CSV keeps the digitiser's own units and `session.json` records the
density.

`flingVel = 420` was calibrated on one iPad Pro 12.9" from four cued swipes and
four cued drags by one person (drags 228–365 pt/s, swipes 453–799 pt/s). It is
**provisional on Android and has never been re-measured there.**

### Layer 1 — board response

| Name | Android | iOS |
|---|---|---|
| Drag start | `viewConfiguration.touchSlop` | `DragGesture(minimumDistance: 14)` pt |
| Hold | `viewConfiguration.longPressTimeoutMillis` (system, nominally 500 ms) | explicit 0.5 s timer (`holdSeconds`) |
| Double-tap window | `viewConfiguration.doubleTapTimeoutMillis` (system, nominally 300 ms) | UIKit default (~300 ms) |
| Flick vs drop | `isFlick`: predicted throw > 120 **px** | predicted throw > 120 **pt** |

---

## 4. The decision, per gesture

### Layer 2: the classifier

One function, `classify(nf, disp, d, meanV, fingers)`. Order matters — the first
matching branch wins.

```
if nf >= 2:
    if |d1 - d0| > pinchDelta   -> "pinch"       # fingers changed separation
    elif dAng > rotateDeg       -> "rotate"      # the pair turned
    else                        -> "multi_tap"
elif disp > moveDist:                            # it travelled
    if meanV > flingVel         -> "swipe"       # a flick
    else                        -> "scroll"      # a drag
else:                                            # it stayed put
    if d > longPressMs          -> "long_press"
    else                        -> "tap"
```

Read as a decision order: **fingers first, then displacement, then duration.**
Displacement is checked before duration, so a stroke that travelled is never a
hold no matter how long it lasted. That is deliberate — a drag can easily run
two seconds, and our drag scenes allow sixteen.

**Double tap has no branch here, and cannot have one.** The classifier sees one
stroke at a time; a double tap is two strokes. It is resolved only at layer 3,
by counting.

Note the vocabulary mismatch between layers: the classifier emits `swipe` for a
flick and `scroll` for a drag, which is why the gesture book's accepted labels
are `swipe -> ["swipe"]` and `drag -> ["scroll"]`.

### Layer 1: the board

| Gesture | How the board recognises it |
|---|---|
| **tap** | Tap recogniser fires after the double-tap window closes with no second tap. Card flips with the slow spin. |
| **double tap** | Two taps inside the double-tap window. Card flips fast. |
| **press & hold** | Finger down, not travelled past slop, still down at 500 ms. Circular reveal opens; retracts on release. |
| **flick** | Travelled past slop, released with predicted throw > 120, **not** over another block. Card leaves along the *cued* direction. |
| **drag** | Travelled past slop, released **over another block**. Card moves there. Released short of anywhere: it animates home and logs `dropMissed`. |

Flick and drag start identically and are separated only at release, by where the
card ended — the grid decides, because only it knows where the other blocks are.
Landing on a block beats throw speed: a fast throw that lands on a block is a
drop, not a flick.

The card leaves along the **cued** direction, not the measured one. The measured
direction from `predicted = acc + lastDelta * 8` is noisy at lift-off and
sometimes points backwards.

### Layer 3: the verdict

Per scene, over the strokes collected during it.

**iOS** (`TrialRunner.score`):
1. No accepted labels in the book -> unscored (`nil`). The trial is still good data.
2. No strokes -> `false`.
3. Cued gesture is `double_tap` -> `taps >= 2`.
4. Otherwise `accepted.contains(first.type)`, and if the scene has a verifiable
   cardinal direction, also `directionMatches` — dominant axis, correct sign,
   at least 15 pt of travel.
5. Travelling scene (drag) -> the verdict is **replaced** by `landedCorrectly`:
   did the card reach the cued block? Where it landed is better evidence than
   which way the stroke went, because a short drag in roughly the right
   direction used to pass while stopping halfway.

**Android** (`TrialRunner.matchOf`): freeform -> unscored; no accepted labels ->
unscored; timeout -> `"0"`; else `observed in acceptedLabels`.

---

## 4a. Where the code is

A tap travels **two independent paths that never meet**. The board flipping the
card and the word `tap` appearing in `_gestures.csv` are produced by completely
separate code. That is deliberate — the deck is app-level ground truth that does
not depend on the classifier — but it is the thing to understand before reading
either one.

### Path A — the board responds (layer 1)

| | Android | iOS |
|---|---|---|
| tap | `CardDeck.kt:411` `onTap` | `CardDeck.swift:296` -> `:400` `tapped()` |
| double tap | `CardDeck.kt:398` `onDoubleTap` | `CardDeck.swift:295` -> `:408` `doubleTapped()` |
| hold | `CardDeck.kt:417` `onLongPress` | `CardDeck.swift:313` `pressing` -> `:379` `armHold()` |
| press state | `CardDeck.kt:421` `onPress` | `CardDeck.swift:313` `pressing` |
| flick / drag split | `StudyScreen.kt:201` `endCarry` | `StudyView.swift:366` `endCarry` |

### Path B — the stroke is recorded and labelled (layers 2 and 3)

| Step | Android | iOS |
|---|---|---|
| every touch enters | `MainActivity.kt:379` `dispatchTouchEvent` | `TouchLogger.swift:51` `touchesBegan` |
| fed to the assembler | `Recorder.kt:170-177` | `Recorder.swift:239-243` |
| stroke finalised | `GestureClassifier.kt:135` `finalizeStroke` | `GestureClassifier.swift` `finalize` |
| **labelled** | `GestureClassifier.kt:161` `classify` (tap at `:176`) | `GestureClassifier.swift:127` `classify` (tap at `:142`) |
| handed to the runner | `MainActivity.kt:82` -> `TrialRunner.kt:167` | `ContentView.swift:95` -> `TrialRunner.swift:198` |
| **verdict** | `TrialRunner.kt:312` `matchOf` | `TrialRunner.swift:316` `score` |

### How much code

| | Android | iOS |
|---|---|---|
| `GestureClassifier` | 178 | 144 |
| `CardDeck` (whole file) | 507 | 494 |
| `StudyScreen` / `StudyView` (whole file) | 715 | 676 |
| `TrialRunner` (whole file) | 334 | 382 |

The two `CardDeck` and board files are mostly card drawing, deck textures and
grid layout. The gesture decisions themselves are roughly 150-200 lines per
platform, and `classify` — the function that actually names the gesture — is 17
lines. `tools/gesture_parse.py` is 122 lines for the offline equivalent.

---

## 5. Divergences and defects

All four are Android-side gaps against iOS, found by reading the two scorers
side by side. None of them affects the raw IMU, touch or BLE streams.

1. **Double tap is over-credited on Android.** `double_tap`'s accepted label is
   `["tap"]`, and Android only checks membership — so a *single* tap on a
   double-tap scene scores `match = 1`. iOS requires `taps >= 2`.

2. **Android never checks direction.** iOS runs `directionMatches` on cardinal
   scenes. Android scores a flick-left as correct when the participant flicked
   right.

3. **Android never checks where the card landed.** `droppedOn` is assigned in
   `cardDropped` and **never read** — it is dead state. iOS overrides the drag
   verdict with it.

4. **`observed` is picked differently.** Android takes the stroke with the
   longest path; iOS takes the first. On a double tap these are different
   strokes.

Two more, of a different kind:

5. **The flick threshold has a unit bug.** `isFlick` compares against `120f` in
   **pixels** on Android and 120 **points** on iOS. The Pixel Tablet runs at
   density 2.0, so its flick threshold is physically **half** the iPad's — a
   throw that flicks on the Pixel is a failed drop on the iPad. This is the same
   class of mistake `GestureThresholds.scaled` exists to prevent, missed because
   `isFlick` lives in `CardDeck.kt` rather than in the classifier.

6. **The release point used to be left out of `path_len`** (fixed 2026-09-16,
   spec 3). `ended()` moved the finger to the release coordinate without adding
   that segment to the path, so `disp` counted it and `path` did not - producing
   strokes whose path was shorter than the straight line between their own
   endpoints. Three of eight travelling strokes in session `0915_2058`, every
   one a flick. Replaying that session's raw touches through both versions:
   worst case `path 197.2 -> 231.5` and `mean_vel 1480 -> 1738`, a 17%
   under-measurement, and zero strokes left with `path < disp`. No label flipped
   in that session because those strokes were well clear of `flingVel`, but 17%
   is more than enough to flip a borderline one. `tools/gesture_parse.py` never
   had it: its `x1,y1` come from the last `pos()` call, which is also the last
   point added to the path.

7. **`tools/gesture_parse.py` is on different numbers.** `D_MOVE = 40`,
   `V_FLING = 800`, against the apps' 10 and 420. The Python works in raw
   `getevent` device units from adb captures, so they are not directly
   comparable — but the header comment claiming all three implementations agree
   is not currently true, and anything reclassified offline will not match what
   the tablets wrote.

### Layer-1 thresholds are not ours

Android reads `longPressTimeoutMillis` and `doubleTapTimeoutMillis` from the
system `ViewConfiguration`, which honours **Settings -> Accessibility -> Touch
and hold delay**. A participant's tablet set to Medium holds at ~1 s. Nothing in
the recording would say so. iOS no longer has this exposure for the hold, since
it times its own; it still does for the double-tap window.

---

## 5a. Provenance recorded with every session

`session.json` carries the rules the labels were produced under, because
`_gestures.csv` stores the features alongside the label and so can be relabelled
offline — but only if you know what the stored label meant.

```json
"app_build": "c244acc",
"classifier": { "spec_version": 2, "units": "pixels", "density": 2,
                "long_press_ms": 500, "move_dist": 20,
                "fling_vel": 840, "pinch_delta": 40, "rotate_deg": 15 }
```

The thresholds are the density-scaled ones actually in force, in the units the
CSV is written in. `GESTURE_SPEC_VERSION` lives beside the thresholds in
`GestureClassifier`, so changing one without bumping it means editing adjacent
lines. Android stamps the git short SHA from Gradle; iOS reads a `GitSHA`
Info.plist key that nothing sets yet and records `"unknown"` until a Run Script
build phase is added.

## 5b. Touch sampling

`_touches_raw.csv` is every sample the digitiser produced, not every callback
the UI framework delivered. Both platforms now read the full rate:

- **Android** — `MotionEvent.historySize` with `getHistoricalX/Y/EventTime`,
  written before the current sample so the stroke is in order.
- **iOS** — `event.coalescedTouches(for:)`. Identity stays with the delivered
  touch, because coalesced samples are separate `UITouch` objects and keying the
  slot table off them would give every sample its own finger id. A `began` is
  never expanded; on other phases only the last sample carries the real phase.

Positions keep one decimal on both platforms, and iOS uses `preciseLocation`.
`path_len` is a sum of successive differences, so truncation accumulates across
a stroke.

This was one-sided until 2026-09-16. iOS dropped the `UIEvent` and logged one
sample per callback: session `0909_1215` holds 3.6 KB of raw touch from the iPad
against 17.4 KB from the Pixel over the same twenty scenes, and one iPad swipe
recorded `path_len 133.3` against `disp 133.7` — a path shorter than the
displacement, which a real finger cannot produce. Under-sampled path means
under-measured `mean_vel`, which pushes an iPad swipe below `flingVel` and
labels it `scroll` where the Pixel would say `swipe`. **Sessions recorded before
that date under-measure iPad path length and velocity**; `app_build` and
`spec_version` are what distinguish them.

## 6. Open

- Recalibrate `flingVel` on Android hardware. The current value comes from four
  strokes on a different device by one person.
- Decide whether `max_vel` separates flick from drag better than `mean_vel`
  (iPad: drags 826–1400, swipes 2471–3892). Changing it means changing all three
  implementations together.
- A hold that outlasts its scene logs `peek` with no `peekEnd` on both
  platforms: the scene wipe clears `peeking` while the finger is still down.
