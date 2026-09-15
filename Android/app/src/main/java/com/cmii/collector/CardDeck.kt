package com.cmii.collector

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * A block is a deck of animal cards. The Android half of CardDeck.swift.
 *
 * Same reason for existing as on the iPad: every gesture in the vocabulary acts
 * on this one object, and a card visibly flipping is evidence the tap landed
 * that does not come from the classifier.
 *
 * Same reason for being a port rather than a fresh design: two tablets running
 * two halves of one play have to present the same board. A participant handed a
 * Pixel showing coloured rectangles and an iPad showing card decks is not doing
 * the same task twice.
 */

// MARK: - Identity

enum class DeckTexture { STRIPES, DOTS, GRID, CHEVRONS, RINGS, WAVES }

/**
 * Colour plus texture, one pairing per deck, stable for a session.
 *
 * Colour is what survives the cell shrinking: at 4x4 the card is small enough
 * that a fine pattern turns to grey mush, and only the hue still identifies the
 * deck.
 */
data class DeckBack(val hue: Float, val texture: DeckTexture) {
    val color: Color get() = Color.hsv(hue * 360f, 0.55f, 0.78f)
    val deep: Color get() = Color.hsv(hue * 360f, 0.65f, 0.55f)

    companion object {
        // The same hues and the same order as DeckBack.forBlock on iOS, so block
        // 3 is the same colour on both tablets.
        private val hues = listOf(0.02f, 0.09f, 0.14f, 0.33f, 0.52f, 0.58f, 0.72f, 0.85f, 0.95f)

        fun forBlock(i: Int) = DeckBack(
            hue = hues[i % hues.size],
            texture = DeckTexture.entries[i % DeckTexture.entries.size])
    }
}

// MARK: - State

/**
 * How the face arrives. The gesture that revealed the card chooses this, so the
 * animation is feedback about what the participant actually did: a slow spin
 * means "that was read as a tap", a snap means "double tap", a spreading circle
 * means "hold".
 *
 * It is cosmetic only. Nothing downstream reads it - the classifier's verdict
 * and the deck event are both written at the moment of the gesture, before any
 * of this has finished playing.
 */
enum class RevealStyle {
    FLIP,    // the plain half-turn: drag and flick scenes, and any other reveal
    SPIN,    // tap: one and a half turns, slow enough to watch
    FAST,    // double tap: the same half-turn, snapped
    CIRCLE   // hold: no rotation, the face spreads from the centre
}

/**
 * Reset at the start of every scene. Without that the board drifts: a deck that
 * has been flicked twice looks nothing like a fresh one, and trial 20 stops
 * being comparable to trial 2.
 */
data class DeckState(
    val discarded: Int = 0,           // cards flicked away, revealing the one beneath
    val faceUp: Boolean = false,      // top card flipped
    val peeking: Boolean = false,     // held down: face shown until release
    val received: List<String> = emptyList(),  // cards dragged here from elsewhere
    val reveal: RevealStyle = RevealStyle.FLIP
) {
    val showsFace: Boolean get() = faceUp || peeking
}

/**
 * Tap's spin. David asked for a full second; this is shorter on purpose.
 *
 * A tap scene and a double-tap scene look identical, so a participant who is
 * unsure whether the first tap registered taps again - and if the card is still
 * turning a second later, that second tap lands inside the double-tap window
 * and the trial is recorded as the wrong gesture. Settling before the window is
 * comfortably closed removes the reason to tap twice.
 */
private const val SPIN_MS = 600
private const val FAST_MS = 120
private const val FLIP_MS = 220
private const val CIRCLE_MS = 420

/** What the deck actually did, independent of what the classifier decided. */
enum class DeckEvent(val wire: String) {
    FLIP("flip"), UNFLIP("unflip"), PEEK("peek"), PEEK_END("peekEnd"),
    DISCARD("discard"), PICK_UP("pickUp"), DROPPED("dropped"),
    DROP_MISSED("dropMissed")
}

// MARK: - Card

/**
 * One card. Standalone so the grid can draw a floating copy under the finger; a
 * card dragged inside its own cell would be clipped by the neighbouring block.
 */
@Composable
fun CardFace(
    back: DeckBack,
    faceUp: Boolean,
    /** An SF Symbol name, as the server and both CSVs use. */
    animal: String,
    cardSize: Dp,
    lifted: Boolean = false,
    modifier: Modifier = Modifier
) {
    val radius = cardSize * 0.11f
    val shape = RoundedCornerShape(radius)
    Box(
        modifier
            .size(cardSize, cardSize * 1.35f)
            .shadow(if (lifted) 6.dp else 3.dp, shape)
            .clip(shape)
            .drawBehind {
                drawRect(if (faceUp) Color(0xFFFCFCFC) else back.color)
                if (!faceUp) texture(back.texture, back.deep.copy(alpha = 0.55f))
                drawRoundRectStroke(
                    if (faceUp) back.deep.copy(alpha = 0.5f) else Color.Black.copy(alpha = 0.18f),
                    radius.toPx())
            },
        contentAlignment = Alignment.Center
    ) {
        if (faceUp && animal.isNotEmpty()) {
            // Sized off the card rather than fixed, for the same reason the iPad
            // pads by a fraction: the 4x4 grid shrinks the card to ~70dp and a
            // constant glyph would overflow it.
            Text(Animals.glyph(animal), fontSize = (cardSize.value * 0.44f).sp,
                 textAlign = TextAlign.Center)
        }
    }
}

private fun DrawScope.drawRoundRectStroke(color: Color, r: Float) {
    drawRoundRect(
        color = color,
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
        style = Stroke(width = 2.dp.toPx()))
}

/**
 * The pattern drawn over a card back. Kept coarse on purpose: fine detail is
 * invisible once a 4x4 cell shrinks the card.
 */
private fun DrawScope.texture(texture: DeckTexture, tint: Color) {
    val w = size.width
    val h = size.height
    val step = max(10f, min(w, h) / 5f)
    val p = Path()
    when (texture) {
        DeckTexture.STRIPES -> {
            var x = -h
            while (x < w) { p.moveTo(x, 0f); p.lineTo(x + h, h); x += step }
        }
        DeckTexture.GRID -> {
            var x = step / 2
            while (x < w) { p.moveTo(x, 0f); p.lineTo(x, h); x += step }
            var y = step / 2
            while (y < h) { p.moveTo(0f, y); p.lineTo(w, y); y += step }
        }
        DeckTexture.CHEVRONS -> {
            var y = -step
            while (y < h + step) {
                p.moveTo(0f, y); p.lineTo(w / 2, y + step / 2); p.lineTo(w, y)
                y += step
            }
        }
        DeckTexture.WAVES -> {
            var y = step / 2
            while (y < h) {
                p.moveTo(0f, y)
                var x = 0f
                while (x < w) {
                    p.quadraticBezierTo(x + step / 2, y - step / 2, x + step, y)
                    x += step
                }
                y += step
            }
        }
        DeckTexture.DOTS -> {
            var y = step / 2
            while (y < h) {
                var x = step / 2
                while (x < w) {
                    p.addOval(Rect(Offset(x - step / 6, y - step / 6),
                                   Size(step / 3, step / 3)))
                    x += step
                }
                y += step
            }
        }
        DeckTexture.RINGS -> {
            var r = step / 2
            while (r < max(w, h)) {
                p.addOval(Rect(Offset(w / 2 - r, h / 2 - r), Size(r * 2, r * 2)))
                r += step / 1.5f
            }
        }
    }
    if (texture == DeckTexture.DOTS) drawPath(p, tint)
    else drawPath(p, tint, style = Stroke(width = max(1.5f, step / 8)))
}

// MARK: - Deck

/**
 * A stack of cards in one block.
 *
 * Only the cued deck responds. A non-target deck that flipped when tapped would
 * reward tapping the wrong one, and the point of the cue is that the participant
 * goes to the right block. Off-target taps are still recorded - the recorder
 * sits on dispatchTouchEvent, so the data is kept even though the card does
 * nothing.
 */
@Composable
fun CardDeckView(
    block: Int,
    animals: List<String>,
    live: Boolean,
    interactive: Boolean,
    cardSize: Dp,
    state: DeckState,
    carrying: Boolean = false,
    onState: (DeckState) -> Unit,
    onEvent: (DeckEvent) -> Unit = {},
    onDragChanged: (Offset) -> Unit = {},
    onDragEnded: (Offset, Offset) -> Unit = { _, _ -> },
    modifier: Modifier = Modifier
) {
    val back = remember(block) { DeckBack.forBlock(block) }
    val depth = max(1, animals.size - state.discarded) + state.received.size
    val top = topAnimalOf(animals, state)
    val density = LocalDensity.current

    // How far the card turns, and how fast, is chosen by the gesture that
    // revealed it. CIRCLE does not turn at all - it stays face down and the
    // face spreads over it, below.
    val turn = when {
        !state.showsFace -> 0f
        state.reveal == RevealStyle.CIRCLE -> 0f
        state.reveal == RevealStyle.SPIN -> 540f   // a turn and a half
        else -> 180f
    }
    val spin by animateFloatAsState(
        targetValue = turn,
        animationSpec = tween(
            when (state.reveal) {
                RevealStyle.SPIN -> SPIN_MS
                RevealStyle.FAST -> FAST_MS
                else -> FLIP_MS
            }),
        label = "flip")

    // The face swaps whenever the card is edge-on rather than at a fixed angle:
    // rotating past 90 degrees shows the layer mirrored, and with the spin
    // passing 90, 270 and 450 there are three such crossings, not one.
    val faceShowing = cos(spin * PI.toFloat() / 180f) < 0f

    // Hold's circle, 0 closed and 1 covering the card. It runs back to 0 on
    // release, so letting go retracts the reveal instead of cutting it.
    val iris by animateFloatAsState(
        targetValue = if (state.showsFace && state.reveal == RevealStyle.CIRCLE) 1f else 0f,
        animationSpec = tween(CIRCLE_MS), label = "iris")

    Box(modifier.size(cardSize, cardSize * 1.35f), contentAlignment = Alignment.Center) {
        // Cards beneath, peeking out so the stack reads as a stack.
        for (i in 0 until max(0, depth - 1)) {
            val d = (depth - 1 - i) * 3.5f
            CardFace(back = back, faceUp = false, animal = "", cardSize = cardSize,
                     modifier = Modifier.offset(d.dp, d.dp))
        }

        // Gestures go on an UNTRANSFORMED wrapper, and the flip rotation goes on
        // the card inside it.
        //
        // They used to share one layer, and that inverted the drag. Compose maps
        // pointer positions back through a graphicsLayer, so at rotationY = 180
        // the layer is mirrored and a finger moving left reports local deltas
        // moving right. It stayed hidden while cards were face down during a
        // gesture; revealing the card on drag and flick scenes set spin to 180
        // and the drag started running backwards. Vertical was always fine -
        // rotationY does not touch y.
        // Everything the gesture handlers read goes through rememberUpdatedState.
        //
        // pointerInput is keyed on the block, so its coroutine keeps running
        // across recompositions and the lambdas inside it hold whatever `state`
        // was current when it started - always the fresh deck. The hold showed
        // it: onLongPress set peeking, and the release then tested a captured
        // `state` that still said peeking was false, so it neither hid the face
        // nor wrote peekEnd. The card stayed revealed and the CSV lost half the
        // pair.
        val cur by rememberUpdatedState(state)
        val emit by rememberUpdatedState(onState)
        val note by rememberUpdatedState(onEvent)

        var g: Modifier = Modifier
        if (interactive) {
            g = g
                .pointerInput(block) {
                    detectTapGestures(
                        // Double first: a single-tap handler that fired
                        // immediately would flip before the second tap arrived,
                        // and the unflip would have nothing to undo.
                        onDoubleTap = {
                            if (cur.faceUp) {
                                emit(cur.copy(faceUp = false, reveal = RevealStyle.FAST))
                                note(DeckEvent.UNFLIP)
                            } else {
                                // On a double-tap scene the card starts face
                                // down, so the second tap has to reveal it -
                                // otherwise the cued gesture is the one gesture
                                // on the board that does nothing.
                                emit(cur.copy(faceUp = true, reveal = RevealStyle.FAST))
                                note(DeckEvent.FLIP)
                            }
                        },
                        onTap = {
                            if (!cur.faceUp) {
                                emit(cur.copy(faceUp = true, reveal = RevealStyle.SPIN))
                                note(DeckEvent.FLIP)
                            }
                        },
                        onLongPress = {
                            emit(cur.copy(peeking = true, reveal = RevealStyle.CIRCLE))
                            note(DeckEvent.PEEK)
                        },
                        onPress = {
                            // The face is shown only while held, so the release
                            // has to end it however the press ends.
                            tryAwaitRelease()
                            if (cur.peeking) {
                                emit(cur.copy(peeking = false)); note(DeckEvent.PEEK_END)
                            }
                        })
                }
                .pointerInput(block) {
                    var acc = Offset.Zero
                    var last = Offset.Zero
                    detectDragGestures(
                        onDragStart = { acc = Offset.Zero; last = Offset.Zero },
                        onDrag = { change, delta ->
                            change.consume()
                            last = delta
                            acc += delta
                            onDragChanged(acc)
                        },
                        onDragEnd = {
                            // Compose has no predictedEndTranslation, so the
                            // throw is estimated from the last delta - the same
                            // quantity iOS's prediction is mostly made of.
                            onDragEnded(acc, acc + last * 8f)
                        },
                        onDragCancel = { onDragEnded(acc, acc) })
                }
        }

        Box(g) {
            CardFace(back = back, faceUp = faceShowing, animal = top,
                     cardSize = cardSize, lifted = live,
                     modifier = Modifier.graphicsLayer {
                         rotationY = spin
                         alpha = if (carrying) 0f else 1f
                         cameraDistance = 14f * density.density
                     })

            // Hold's reveal: the face laid over the back, showing only inside a
            // circle that grows from the centre. Drawn as a second card rather
            // than by clipping the first, because the first is the one the
            // rotation and the carry-alpha act on and this one must do neither.
            if (iris > 0.001f && !carrying) {
                CardFace(back = back, faceUp = true, animal = top,
                         cardSize = cardSize, lifted = live,
                         modifier = Modifier.clip(Iris(iris)))
            }
        }
    }
}

/**
 * A circle centred on the card, `f` of the way to covering it.
 *
 * The radius runs to half the diagonal, not half the width: a circle that only
 * reaches the long edges would leave the four corners permanently hidden, and
 * the hold is meant to end with the whole card visible.
 */
private class Iris(private val f: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection,
                               density: Density): Outline {
        val r = f * hypot(size.width, size.height) / 2f
        val c = Offset(size.width / 2f, size.height / 2f)
        return Outline.Generic(Path().apply {
            addOval(Rect(Offset(c.x - r, c.y - r), Size(r * 2, r * 2)))
        })
    }
}

/** The card currently on top: the last one dropped here, else the next undiscarded. */
fun topAnimalOf(animals: List<String>, state: DeckState): String {
    state.received.lastOrNull()?.let { return it }
    if (animals.isEmpty()) return Animals.fallback
    return animals[min(state.discarded, animals.size - 1)]
}

/** Was this release a throw rather than a placement? Matches the iPad's 120pt. */
fun isFlick(predicted: Offset): Boolean = hypot(predicted.x, predicted.y) > 120f
