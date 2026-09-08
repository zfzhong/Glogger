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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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
 * Reset at the start of every scene. Without that the board drifts: a deck that
 * has been flicked twice looks nothing like a fresh one, and trial 20 stops
 * being comparable to trial 2.
 */
data class DeckState(
    val discarded: Int = 0,           // cards flicked away, revealing the one beneath
    val faceUp: Boolean = false,      // top card flipped
    val peeking: Boolean = false,     // held down: face shown until release
    val received: List<String> = emptyList()  // cards dragged here from elsewhere
) {
    val showsFace: Boolean get() = faceUp || peeking
}

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

    // The flip is drawn rather than animated card-by-card: rotating the Y axis
    // past 90 degrees would show a mirrored face, so the face swaps at the
    // halfway point instead.
    val spin by animateFloatAsState(
        targetValue = if (state.showsFace) 180f else 0f,
        animationSpec = tween(220), label = "flip")

    Box(modifier.size(cardSize, cardSize * 1.35f), contentAlignment = Alignment.Center) {
        // Cards beneath, peeking out so the stack reads as a stack.
        for (i in 0 until max(0, depth - 1)) {
            val d = (depth - 1 - i) * 3.5f
            CardFace(back = back, faceUp = false, animal = "", cardSize = cardSize,
                     modifier = Modifier.offset(d.dp, d.dp))
        }

        var g = Modifier
            .graphicsLayer {
                rotationY = spin
                alpha = if (carrying) 0f else 1f
                cameraDistance = 14f * density.density
            }
        if (interactive) {
            g = g
                .pointerInput(block) {
                    detectTapGestures(
                        // Double first: a single-tap handler that fired
                        // immediately would flip before the second tap arrived,
                        // and the unflip would have nothing to undo.
                        onDoubleTap = {
                            if (state.faceUp) {
                                onState(state.copy(faceUp = false)); onEvent(DeckEvent.UNFLIP)
                            }
                        },
                        onTap = {
                            if (!state.faceUp) {
                                onState(state.copy(faceUp = true)); onEvent(DeckEvent.FLIP)
                            }
                        },
                        onLongPress = {
                            onState(state.copy(peeking = true)); onEvent(DeckEvent.PEEK)
                        },
                        onPress = {
                            // The face is shown only while held, so the release
                            // has to end it however the press ends.
                            tryAwaitRelease()
                            if (state.peeking) {
                                onState(state.copy(peeking = false)); onEvent(DeckEvent.PEEK_END)
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
            CardFace(back = back, faceUp = state.showsFace, animal = top,
                     cardSize = cardSize, lifted = live,
                     // Counter-rotated so the face is not mirrored by the spin.
                     modifier = Modifier.graphicsLayer {
                         rotationY = if (spin > 90f) 180f else 0f
                     })
        }
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
