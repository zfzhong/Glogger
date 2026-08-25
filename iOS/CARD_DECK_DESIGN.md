# The card-deck block

Status: **designed, not built.** Supersedes the per-gesture affordances sketched in
`GESTURE_STUDY_SPEC.md` §3 (zoomable image / rotatable image / scrollable strip).

## Why

Each block becomes a **deck of animal cards**. Every gesture in the vocabulary acts
on the same object, so the six unbuilt conditions stop being three separate
components and become one.

It also buys **app-level ground truth**. Today the only evidence a tap happened is
`GestureClassifier` returning `"tap"`. If a card visibly flips, the deck's state
change confirms the intended interaction independently of the classifier - stronger
than the `match` column, and it retires the unverifiable cases (`pinch` IN vs OUT,
`rotate` CW vs CCW) that geometry cannot adjudicate.

And it is a card game rather than "tap the highlighted square", which matters for
the children in the pilot.

## Gesture semantics

| gesture | on a deck | state change = ground truth |
|---|---|---|
| `tap` | flip the top card, revealing the animal | card face up |
| `double_tap` | flip it back face down | card face down again |
| `long_press` | peek: hold to see the face, released it returns | face shown while held |
| `swipe` (flick) | discard the top card, revealing the one beneath | depth +1 |
| `drag` | carry the top card to another deck | card present in destination |
| `scroll` | browse down through the deck | scroll offset |
| `pinch` | zoom the top card to inspect it | scale factor |
| `rotate` | turn the top card | rotation angle |

`swipe` stays ballistic (no destination); `drag` travels to the destination deck
already carried on the scene as `toRow`/`toCol`.

## Two decisions that are easy to get wrong

**Decks must stay tellable apart while face-down.** The search task - the
participant finding the cued deck - only works because the blocks currently show
different animals. Face-down cards are identical, and search would collapse to
"look for the highlight". So **each deck has its own card back**: a distinct colour
plus a small icon, stable for the whole session. The animal on the face stays the
reward for flipping, not the identifier.

**Deck state resets at the start of every scene.** Otherwise the board drifts: a
deck that has been flicked four times looks nothing like a fresh one, trial 20 is
not comparable to trial 2, and the visual scene becomes a confound that grows
monotonically through the session. Reset costs realism and buys comparability;
for a measurement study that is the right trade.

Consequence worth stating: the participant will see cards reappear. That is
acceptable - they are not playing a game with a goal, they are performing cued
gestures.

## Build order

1. `CardDeckView` - stack rendering, distinct backs, flip animation, reset hook.
2. Wire `tap` / `double_tap` / `long_press` / `swipe` to it. These are already
   built as conditions, so this is a visual upgrade with no schedule change.
3. `drag` across decks, using the destination the scene already carries.
4. `scroll`, then `pinch` + `rotate` together (shared recogniser setup).
5. Flip `built` on `scroll`, `pinch`, `rotate` in the gesture book - that is all
   that is needed to make them schedulable, the payload already carries them.

## Open

- Deck depth. Deep enough that `swipe` never empties one within a scene's window.
- Does the card face need to be the animal at all, or is a colour enough? The
  animal is currently what makes each block identifiable; with distinct backs
  doing that job, the face could carry something else.
- Whether app-level state should be logged as its own CSV (`_deck.csv`) or folded
  into `trials.csv` as extra columns.
