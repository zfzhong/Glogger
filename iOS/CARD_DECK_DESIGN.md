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

## Settled parameters

- **Deck depth 5**, five different animals per deck. With per-trial reset a deck
  only has to survive one scene, and the most any scene consumes is one card, so 5
  is generous - it is chosen for how a stack of 5 renders (visible offset edges,
  not cluttered) rather than for capacity. Faces repeat across decks; there are
  only 11 symbols in the pool and the backs carry deck identity anyway.
- **Backs are colour plus texture**, one pairing per deck, stable for the session.
  Colour survives the cell shrinking - artwork drops to 100pt at 3x3 and 70pt at
  4x4, where a fine pattern alone turns to grey mush. The texture gives each deck a
  nameable identity and keeps it distinguishable in a greyscale screenshot.
- **The cued deck is highlighted**, as today: accent border and tinted fill.

## Two decisions that are easy to get wrong

**How much the backs have to carry depends on how the target is cued, and the
choice is: highlight.** An earlier draft of this document claimed that face-down
cards would collapse the search task. That was overstated. Because the cue is a
highlight rather than a spoken name, the participant looks for the glow and the
backs are not the experimental stimulus - they only need to look like distinct
decks. Colour plus texture is comfortably enough for that.

The alternative - naming the target ("flip a card in the striped deck") and
removing the highlight - would make the backs load-bearing and add a genuine
visual-search phase before the motor act. Deliberately not taken for now: it
changes trial timing and risks timeouts. Worth revisiting as its own condition.

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
