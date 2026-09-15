package com.cmii.collector

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.toSize
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.Density
import kotlin.math.max
import kotlin.math.min

/**
 * The cue screen.
 *
 * Each block is a deck of animal cards, the same object the iPad board is built
 * from: every gesture in the vocabulary acts on it, and the card's own behaviour
 * - flipped, discarded, dropped on a neighbour - is ground truth that does not
 * come from the classifier.
 *
 * One block is live at a time; the rest stay visible so the layout, and
 * therefore the reach distances, stay constant. The grid is whatever the scene
 * says, not a fixed 2x2: a hardcoded grid would silently drop every scene
 * addressed to row or column 2, the participant would see nothing to do, and the
 * scene would time out looking like a miss.
 *
 * No verdict is shown. A participant told they got it wrong performs the next
 * gesture differently.
 */
@Composable
fun StudyScreen(
    runner: TrialRunner,
    waitingText: String,
    onWebEvent: (String, String) -> Unit = { _, _ -> }
) {
    // A web scene takes the whole screen apart from a thin operator strip.
    // GAP is part of the scene, not a pause between scenes.
    //
    // The runner leaves the cue window and sits in GAP until the slot ends. That
    // used to be invisible, because the scene advanced a moment later. Now that
    // the slot is what advances it, a screen keyed on the earlier phases blanked
    // itself for the last seconds of its own scene - the waiting message
    // disappearing while the counter still said the scene was running.
    val web = runner.current?.takeIf {
        it.isWeb && runner.phase in listOf(TrialRunner.Phase.READY, TrialRunner.Phase.CUED,
                                           TrialRunner.Phase.SETTLING, TrialRunner.Phase.GAP)
    }
    if (web != null) { WebBody(runner, web, onWebEvent); return }
    CardBoard(runner, waitingText)
}

@Composable
private fun WebBody(runner: TrialRunner, t: Trial, onWebEvent: (String, String) -> Unit) {
    // Reset whenever the scene changes, so a second web scene starts on its own
    // menu rather than wherever the last one was left.
    var picked by remember(t.i) { mutableStateOf<WebSite?>(null) }
    val live = picked?.link ?: t.webUrl.takeIf { t.siteList.isEmpty() }

    Column(Modifier.fillMaxSize()) {
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                if (t.siteList.isNotEmpty() && picked != null)
                    TextButton(onClick = { picked = null; onWebEvent("menu", "") }) {
                        Text("Games")
                    }
                Text("Scene ${minOf(runner.index + 1, runner.total)} of ${runner.total}",
                     style = MaterialTheme.typography.bodySmall)
                Text(picked?.label ?: t.promptText,
                     style = MaterialTheme.typography.bodySmall,
                     maxLines = 1,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                LinearProgressIndicator(
                    progress = { if (runner.total > 0) runner.nDone / runner.total.toFloat() else 0f },
                    modifier = Modifier.width(150.dp))
            }
        }
        if (live != null) {
            key(t.i, live) {
                WebScene(live, onWebEvent, Modifier.fillMaxSize())
            }
        } else {
            SiteMenu(t.promptText, t.siteList) { picked = it; onWebEvent("pick", it.url) }
        }
    }
}

@Composable
private fun CardBoard(runner: TrialRunner, waitingText: String) {
    val t = runner.displayTrial
    val play = runner.play
    val rows = t?.rows ?: play?.rows ?: 2
    val cols = t?.cols ?: play?.cols ?: 2

    val quiet: Trial? = runner.current?.takeIf {
        (it.isWaiting || it.isOffscreen) &&
            runner.phase in listOf(TrialRunner.Phase.READY, TrialRunner.Phase.CUED,
                                   TrialRunner.Phase.SETTLING, TrialRunner.Phase.GAP)
    }

    // Deck state per block, wiped between scenes. A deck left flicked twice
    // looks nothing like a fresh one, and trial 20 stops being comparable to
    // trial 2.
    val decks = remember { mutableStateMapOf<Int, DeckState>() }
    var carry by remember { mutableStateOf<Pair<Int, Offset>?>(null) }
    val frames = remember { mutableStateMapOf<Int, Rect>() }
    LaunchedEffect(runner.index) { decks.clear(); carry = null }

    // A drag needs the participant to know WHICH card is being moved, so the
    // card to be dragged is turned face up as the cue appears.
    //
    // Only a travelling scene. On a tap scene the card has to start face down
    // or there is nothing to flip, and the flip is the gesture being measured.
    //
    // At the cue, not at the start of the scene: a face showing during "Get
    // ready" would name the target a second early, and the participant would
    // have their hand there before the scene began.
    LaunchedEffect(runner.index, runner.phase) {
        val t = runner.current
        if (runner.phase == TrialRunner.Phase.CUED && t != null && t.revealsCard) {
            val b = t.row * cols + t.col
            decks[b] = (decks[b] ?: DeckState()).copy(faceUp = true)
        }
    }

    val pool = play?.blockPictures ?: Animals.all
    fun deckAnimals(block: Int): List<String> {
        // Three faces in one deck. Different animals within a deck; the deck is
        // identified by its back rather than by these, so repeats across decks
        // are fine - there are only 11 symbols in the pool.
        if (pool.isEmpty()) return listOf(Animals.fallback)
        // Names, not glyphs: _deck.csv has to say "ant.fill" on both tablets,
        // whatever each one actually draws.
        return (0 until 3).map { pool[(block * 3 + it) % pool.size] }
    }
    fun stateOf(b: Int) = decks[b] ?: DeckState()

    // Where the carried card is right now, in the same root space the cell
    // frames are recorded in. One expression, used by both the drawing and the
    // hit test, so the card cannot be drawn somewhere it would not land.
    val carriedAt: Offset? = carry?.let { (src, off) ->
        frames[src]?.let { Offset(it.center.x + off.x, it.center.y + off.y) }
    }
    fun topOf(b: Int) = topAnimalOf(deckAnimals(b), stateOf(b))

    fun deckEvent(b: Int, e: DeckEvent) =
        runner.deckRow(b, e.wire, topOf(b))

    /** Which block a release landed in, in the grid's coordinate space. */
    fun blockAt(p: Offset): Int? =
        frames.entries.firstOrNull { it.value.contains(p) }?.key

    val hovered: Int? = carriedAt?.let { blockAt(it) }?.takeIf { it != carry?.first }

    // A card that has been thrown and is still leaving. Held apart from the
    // deck state because the deck must not lose the card until the animation
    // that shows it going has finished - otherwise the next card appears
    // underneath the one still flying away.
    var flung by remember { mutableStateOf<Flung?>(null) }

    fun endCarry(src: Int, translation: Offset, predicted: Offset) {
        carry = null
        val f = frames[src] ?: return
        val end = Offset(f.center.x + translation.x, f.center.y + translation.y)
        val st = stateOf(src)
        val animal = topAnimalOf(deckAnimals(src), st)
        val target = blockAt(end)
        val depth = deckAnimals(src).size

        if (target != null && target != src) {
            // Landed on another block: the card moves there.
            decks[src] = st.copy(
                discarded = min(st.discarded + 1, max(0, depth - 1)), faceUp = false)
            val dst = stateOf(target)
            // The arriving card lands face up. Until it did, a drop that
            // worked and a drop that missed left the board looking exactly
            // the same, so nothing on screen said the card had moved.
            decks[target] = dst.copy(received = dst.received + animal, faceUp = true)
            runner.cardDropped(src, target, animal)
        } else if (isFlick(predicted)) {
            // Thrown, but not onto anything: a flick discards the top card. It
            // leaves along the direction it was thrown rather than blinking out
            // of existence, so the throw has a visible consequence.
            // The card leaves along the CUED direction - the way the arrow on
            // screen points - not along the exact angle the finger took. The
            // arrow and the card then agree, and the animation is the same
            // every time rather than being at the mercy of a hand's wobble.
            //
            // Reading it off the gesture was worse than untidy: the direction
            // came from `predicted`, which is accumulated + lastDelta x 8, and
            // the last delta as a finger lifts is small and noisy - sometimes
            // pointing backwards. Multiplied by eight it flipped the sign, and
            // a card flicked right flew left.
            //
            // `predicted` still decides WHETHER it was a throw, which is what
            // it is good for: it stands in for speed.
            val cued = runner.current?.dir
            val v = when (cued) {
                "L" -> Offset(-1f, 0f)
                "R" -> Offset(1f, 0f)
                "U" -> Offset(0f, -1f)   // y grows downward
                "D" -> Offset(0f, 1f)
                // No direction in the cue: fall back to where the hand went.
                else -> if (translation.getDistance() > 1f) translation else predicted
            }
            val len = maxOf(1f, v.getDistance())
            flung = Flung(
                block = src,
                animal = animal,
                from = Offset(f.center.x + translation.x, f.center.y + translation.y),
                dir = Offset(v.x / len, v.y / len))
            runner.cardDropped(src, null, animal)
        }
    }

    // How far the thrown card has travelled, 0 to 1. Read by the board to place
    // and fade it.
    val flight = remember { Animatable(0f) }

    // The deck loses the card when the card is off screen, not when the finger
    // lifted - otherwise the next card appears underneath the one still flying
    // away. The row in _deck.csv was already written at the release, so the
    // timing in the file is the gesture's and not the animation's.
    LaunchedEffect(flung) {
        val f = flung ?: return@LaunchedEffect
        flight.snapTo(0f)
        flight.animateTo(1f, tween(300))
        val depth = deckAnimals(f.block).size
        val st = stateOf(f.block)
        if (st.discarded < depth - 1)
            decks[f.block] = st.copy(discarded = st.discarded + 1, faceUp = false)
        flung = null
    }

    Column(Modifier.fillMaxSize().padding(20.dp),
           verticalArrangement = Arrangement.spacedBy(18.dp)) {

        // Header
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    when (runner.phase) {
                        TrialRunner.Phase.IDLE -> "Not started"
                        TrialRunner.Phase.DONE -> "Finished"
                        else -> "Scene ${minOf(runner.index + 1, runner.total)} of ${runner.total}"
                    },
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(Modifier.weight(1f))
                // Seconds left in the SLOT, not in the cue window. The scene ends
                // when this reaches zero and not before, so the number and the
                // scene counter always agree - finishing the gesture early no
                // longer skips the board forward.
                if (runner.isRunning)
                    Text("${(runner.remainingMs + 999) / 1000}s",
                         style = MaterialTheme.typography.titleMedium,
                         fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            LinearProgressIndicator(
                progress = { if (runner.total > 0) runner.nDone / runner.total.toFloat() else 0f },
                modifier = Modifier.fillMaxWidth()
            )
            Text(
                if (quiet == null) bannerText(runner) else "",
                fontSize = 40.sp, fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().heightIn(min = 56.dp)
            )
        }

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Board(rows, cols, runner, dimmed = quiet != null,
                  animalsOf = ::deckAnimals, stateOf = ::stateOf,
                  onState = { b, s -> decks[b] = s },
                  onEvent = ::deckEvent,
                  carrying = carry?.first,
                  onFrame = { b, r -> frames[b] = r },
                  onDragChanged = { b, off -> carry = b to off },
                  onDragEnded = { b, tr, pred -> endCarry(b, tr, pred) },
                  carried = carry,
                  carriedAt = carriedAt,
                  flung = flung,
                  flight = flight.value,
                  hovered = hovered,
                  topOf = ::topOf,
                  showsFaceOf = { stateOf(it).showsFace })
            when {
                quiet?.isOffscreen == true -> Panel(quiet.promptText, big = true)
                quiet?.isWaiting == true ->
                    // The counter is repeated inside the panel, not just left in
                    // the header: an empty slot IS a scene, and the panel is the
                    // only thing being read while it runs. Without it the run
                    // looks stalled rather than under way.
                    Panel(quiet.promptText.ifBlank { waitingText }, big = false,
                          caption = "Scene ${minOf(runner.index + 1, runner.total)} " +
                                    "of ${runner.total}  ·  " +
                                    "${(runner.remainingMs + 999) / 1000}s")
            }
        }
    }
}

private fun bannerText(runner: TrialRunner): String = when (runner.phase) {
    TrialRunner.Phase.IDLE -> ""
    TrialRunner.Phase.READY -> "Get ready…"
    TrialRunner.Phase.CUED, TrialRunner.Phase.SETTLING -> runner.current?.cueText() ?: ""
    TrialRunner.Phase.GAP -> ""
    TrialRunner.Phase.DONE -> "All done — thank you"
}

private fun Trial.cueText(): String {
    if (isOffscreen) return promptText
    // A travelling scene shows its destination, so naming the direction as well
    // is redundant - the target says where to go.
    if (isTravelling) return displayVerb
    if (dir == null) return displayVerb
    return "$displayVerb $directionWord"
}

@Composable
private fun Board(
    rows: Int, cols: Int, runner: TrialRunner, dimmed: Boolean,
    animalsOf: (Int) -> List<String>,
    stateOf: (Int) -> DeckState,
    onState: (Int, DeckState) -> Unit,
    onEvent: (Int, DeckEvent) -> Unit,
    carrying: Int?,
    onFrame: (Int, Rect) -> Unit,
    onDragChanged: (Int, Offset) -> Unit,
    onDragEnded: (Int, Offset, Offset) -> Unit,
    carried: Pair<Int, Offset>?,
    carriedAt: Offset?,          // where the card is now, in root space
    hovered: Int?,               // the block it would drop on
    flung: Flung?,               // a card thrown and still leaving
    flight: Float,               // how far it has gone, 0 to 1
    topOf: (Int) -> String,
    showsFaceOf: (Int) -> Boolean
) {
    // The board's own origin, so a root-space cell position can be turned back
    // into a position inside this Box.
    var origin by remember { mutableStateOf(Offset.Zero) }
    val gap = if (rows * cols > 9) 10.dp else 16.dp
    val live = runner.current.takeIf {
        runner.phase == TrialRunner.Phase.CUED || runner.phase == TrialRunner.Phase.SETTLING
    }
    val flashing = runner.current?.takeIf {
        runner.phase == TrialRunner.Phase.GAP && !it.isWaiting && !it.isOffscreen
    }
    val big = max(rows, cols)
    val density = LocalDensity.current

    Box(Modifier.fillMaxSize().alpha(if (dimmed) 0.18f else 1f)
               .onGloballyPositioned { origin = it.positionInRoot() }) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(gap)) {
            for (r in 0 until rows) {
                Row(Modifier.fillMaxWidth().weight(1f),
                    horizontalArrangement = Arrangement.spacedBy(gap)) {
                    for (c in 0 until cols) {
                        val b = r * cols + c
                        // A freeform scene still carries a row and column, but
                        // lighting a deck would contradict a screen that says to
                        // do something else - or nothing at all.
                        val isLive = live != null && !live.isFreeform &&
                                     live.row == r && live.col == c
                        val isTarget = live?.isTravelling == true &&
                                       live.toRow == r && live.toCol == c
                        val isFlash = flashing != null &&
                                      flashing.row == r && flashing.col == c
                        // Where the card would land if the finger lifted now.
                        // Without it a drag is a guess until it is released.
                        val isHover = hovered == b && carrying != b
                        Cell(
                            block = b, live = isLive, target = isTarget, flashing = isFlash,
                            hover = isHover,
                            big = big, verb = if (isLive) live?.displayVerb else null,
                            // Only where the direction is part of the task: a
                            // drag or a flick moves the card somewhere, a tap
                            // does not.
                            dir = if (isLive && live?.revealsCard == true) live.dir else null,
                            animals = animalsOf(b), state = stateOf(b),
                            onState = { onState(b, it) },
                            onEvent = { onEvent(b, it) },
                            // The deck keeps the card until the flight ends,
                            // so that the next card does not appear early - but
                            // it must not DRAW it, or there are two copies and
                            // the one sitting still reads as the card snapping
                            // back to the deck.
                            carrying = carrying == b || flung?.block == b,
                            onFrame = { onFrame(b, it) },
                            onDragChanged = { onDragChanged(b, it) },
                            onDragEnded = { tr, pr -> onDragEnded(b, tr, pr) },
                            modifier = Modifier.weight(1f).fillMaxHeight())
                    }
                }
            }
        }

        // The card under the finger, drawn above every block so it can pass over
        // them instead of being clipped by its own cell. It starts exactly where
        // the card it replaces was sitting: a card that jumps to the middle of
        // the board on the first millimetre of movement does not read as having
        // been picked up.
        // A thrown card, on its way out along the direction it was thrown.
        //
        // `flight` is a single animator reused between throws, and on the frame
        // where `flung` is set it still holds 1.0 from the last one - drawing
        // then would flash the card at the far end before it starts. Skipping
        // that frame costs nothing: snapTo(0) lands before the next.
        if (flung != null && flight < 1f) {
            val side = cardSideFor(big)
            val w = with(density) { side.toPx() }
            val h = w * 1.35f
            // Far enough to be gone: the board's own diagonal, so the card
            // leaves the screen rather than stopping at the edge of it.
            val reach = with(density) { 760.dp.toPx() }
            val x = (flung.from.x - origin.x - w / 2f + flung.dir.x * reach * flight).toInt()
            val y = (flung.from.y - origin.y - h / 2f + flung.dir.y * reach * flight).toInt()
            Box(Modifier.align(Alignment.TopStart)
                        .offset { IntOffset(x, y) }
                        .alpha((1f - flight).coerceIn(0f, 1f))) {
                CardFace(back = DeckBack.forBlock(flung.block), faceUp = true,
                         animal = flung.animal, cardSize = side, lifted = true)
            }
        }

        if (carried != null && carriedAt != null) {
            val (b, _) = carried
            val side = cardSideFor(big)
            val w = with(density) { side.toPx() }
            val h = w * 1.35f
            val x = (carriedAt.x - origin.x - w / 2f).toInt()
            val y = (carriedAt.y - origin.y - h / 2f).toInt()
            Box(Modifier.align(Alignment.TopStart).offset { IntOffset(x, y) }) {
                // Face up the instant it lifts, and without a flip
    // animation: a card in the hand is a card you can see, and an
    // animation competing with the drag makes the pickup feel slow.
                CardFace(back = DeckBack.forBlock(b), faceUp = true,
                         animal = topOf(b), cardSize = side, lifted = true)
            }
        }
    }
}

/** Artwork shrinks as the grid grows, so a 3x3 or 4x4 still fits the screen. */
private fun cardSideFor(big: Int): Dp = when {
    big >= 4 -> 70.dp
    big == 3 -> 100.dp
    else -> 150.dp
}

/**
 * One block: the framing around a deck.
 *
 * The frame carries the cue - lit for the live block, dashed for a travelling
 * gesture's destination, a neutral flash for the block just acted on. Neutral
 * on purpose: it acknowledges that something happened without saying whether it
 * was right.
 */
@Composable
private fun Cell(
    block: Int, live: Boolean, target: Boolean, flashing: Boolean, big: Int,
    hover: Boolean = false,
    verb: String?,
    /** "L", "R", "U" or "D" on a directional scene, else null. */
    dir: String? = null,
    animals: List<String>, state: DeckState,
    onState: (DeckState) -> Unit,
    onEvent: (DeckEvent) -> Unit,
    carrying: Boolean,
    onFrame: (Rect) -> Unit,
    onDragChanged: (Offset) -> Unit,
    onDragEnded: (Offset, Offset) -> Unit,
    modifier: Modifier = Modifier
) {
    val radius = if (big >= 4) 14.dp else if (big == 3) 18.dp else 22.dp
    val pad = if (big >= 4) 8.dp else if (big == 3) 12.dp else 18.dp
    val accent = MaterialTheme.colorScheme.primary

    val fill = when {
        // Hover wins over every other state while a card is in the air: what
        // matters at that moment is where it will land.
        hover -> accent.copy(alpha = 0.22f)
        flashing -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.18f)
        live -> accent.copy(alpha = 0.16f)
        target -> Color(0xFF2E7D32).copy(alpha = 0.12f)
        else -> Color.Gray.copy(alpha = 0.10f)
    }
    val stroke = when {
        hover -> accent
        flashing -> MaterialTheme.colorScheme.onSurfaceVariant
        live -> accent
        target -> Color(0xFF2E7D32)
        else -> Color.Black.copy(alpha = 0.25f)
    }
    val scale by animateFloatAsState(if (live) 1f else 0.94f, tween(150), label = "cell")

    Box(
        modifier
            .clip(RoundedCornerShape(radius))
            .background(fill)
            .border(
                width = if (hover) 6.dp else if (live || flashing) 6.dp
                        else if (target) 5.dp else 2.dp,
                color = stroke, shape = RoundedCornerShape(radius))
            .padding(pad)
            .onGloballyPositioned {
                onFrame(Rect(it.positionInRoot(), it.size.toSize()))
            },
        contentAlignment = Alignment.Center
    ) {
        // The cue names a direction in words; this puts it on the board. The
        // arrow sits against the edge the card is meant to travel toward, so
        // the participant does not have to map "right" onto the layout while
        // the clock runs.
        if (live && dir != null) {
            val glyph = when (dir) {
                "L" -> "\u2190"; "R" -> "\u2192"; "U" -> "\u2191"; "D" -> "\u2193"
                else -> ""
            }
            // The card is nearly as tall as the cell but much narrower, so
            // there is room either side of it and almost none above or below.
            // An up arrow at TopCenter lands behind the card and is simply not
            // seen; kept in the side margin it stays clear, and its height in
            // the cell still says which way.
            val where = when (dir) {
                "L" -> Alignment.CenterStart
                "R" -> Alignment.CenterEnd
                "U" -> Alignment.TopEnd
                else -> Alignment.BottomEnd
            }
            if (glyph.isNotEmpty())
                Text(glyph,
                     fontSize = (if (big >= 4) 34 else if (big == 3) 46 else 64).sp,
                     fontWeight = FontWeight.Bold,
                     color = accent,
                     modifier = Modifier.align(where).padding(horizontal = 10.dp))
        }

        Column(horizontalAlignment = Alignment.CenterHorizontally,
               verticalArrangement = Arrangement.spacedBy(if (big >= 4) 6.dp else 14.dp)) {
            Box(Modifier.graphicsLayer { scaleX = scale; scaleY = scale }
                        .alpha(if (target) 0.55f else 1f)) {
                CardDeckView(
                    block = block, animals = animals, live = live,
                    // Only the cued deck responds; off-target touches are still
                    // recorded, they just do not move a card.
                    interactive = live,
                    cardSize = cardSideFor(big), state = state, carrying = carrying,
                    onState = onState, onEvent = onEvent,
                    onDragChanged = onDragChanged, onDragEnded = onDragEnded)
            }
            if (target)
                Text("drop here", color = Color(0xFF2E7D32),
                     fontWeight = FontWeight.SemiBold,
                     style = if (big >= 4) MaterialTheme.typography.labelSmall
                             else MaterialTheme.typography.titleMedium)
            if (live && verb != null)
                Text(verb, color = accent, fontWeight = FontWeight.SemiBold,
                     maxLines = 1,
                     style = if (big >= 4) MaterialTheme.typography.titleSmall
                             else MaterialTheme.typography.headlineSmall)
        }
    }
}

/** The panel shown over a dimmed board: a water break, or the other tablet's turn. */
@Composable
private fun Panel(text: String, big: Boolean, caption: String? = null) {
    Surface(shape = RoundedCornerShape(if (big) 28.dp else 24.dp), tonalElevation = 6.dp) {
        Column(
            Modifier.padding(horizontal = 52.dp, vertical = 32.dp).widthIn(max = 760.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            if (caption != null)
                Text(caption, style = MaterialTheme.typography.titleMedium,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(
                text,
                fontSize = if (big) 40.sp else 44.sp,
                fontWeight = if (big) FontWeight.SemiBold else FontWeight.Light,
                textAlign = TextAlign.Center,
                color = if (big) MaterialTheme.colorScheme.onSurface
                        else MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * The board with nothing happening on it: every deck face down, none live, none
 * touchable.
 *
 * Used behind the countdown while a tablet waits for its scheduled start. It
 * deliberately shows no cue - the layout, so the participant knows where to
 * look, without the instruction, which they would otherwise have several
 * seconds to rehearse.
 */
@Composable
fun StaticBoard(rows: Int, cols: Int, pool: List<String>) {
    val gap = if (rows * cols > 9) 10.dp else 16.dp
    val big = max(rows, cols)
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(gap)) {
        for (r in 0 until rows) {
            Row(Modifier.fillMaxWidth().weight(1f),
                horizontalArrangement = Arrangement.spacedBy(gap)) {
                for (c in 0 until cols) {
                    val b = r * cols + c
                    val animals =
                        if (pool.isEmpty()) listOf(Animals.fallback)
                        else (0 until 3).map { pool[(b * 3 + it) % pool.size] }
                    Cell(block = b, live = false, target = false, flashing = false,
                         big = big, verb = null, animals = animals,
                         state = DeckState(), onState = {}, onEvent = {},
                         carrying = false, onFrame = {}, onDragChanged = {},
                         onDragEnded = { _, _ -> },
                         modifier = Modifier.weight(1f).fillMaxHeight())
                }
            }
        }
    }
}

/**
 * A card that has been thrown and is still leaving.
 *
 * Kept outside the deck state on purpose: the deck must not lose the card until
 * the animation showing it go has finished, or the next card appears underneath
 * the one still in the air.
 */
data class Flung(
    val block: Int,
    val animal: String,
    val from: Offset,
    val dir: Offset
)
