package com.cmii.collector

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
import androidx.compose.ui.layout.boundsInParent
import androidx.compose.ui.layout.onGloballyPositioned
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
    val web = runner.current?.takeIf {
        it.isWeb && runner.phase in listOf(TrialRunner.Phase.READY, TrialRunner.Phase.CUED,
                                           TrialRunner.Phase.SETTLING)
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
                                   TrialRunner.Phase.SETTLING)
    }

    // Deck state per block, wiped between scenes. A deck left flicked twice
    // looks nothing like a fresh one, and trial 20 stops being comparable to
    // trial 2.
    val decks = remember { mutableStateMapOf<Int, DeckState>() }
    var carry by remember { mutableStateOf<Pair<Int, Offset>?>(null) }
    val frames = remember { mutableStateMapOf<Int, Rect>() }
    LaunchedEffect(runner.index) { decks.clear(); carry = null }

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
    fun topOf(b: Int) = topAnimalOf(deckAnimals(b), stateOf(b))

    fun deckEvent(b: Int, e: DeckEvent) =
        runner.deckRow(b, e.wire, topOf(b))

    /** Which block a release landed in, in the grid's coordinate space. */
    fun blockAt(p: Offset): Int? =
        frames.entries.firstOrNull { it.value.contains(p) }?.key

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
            decks[target] = dst.copy(received = dst.received + animal)
            runner.cardDropped(src, target, animal)
        } else if (isFlick(predicted)) {
            // Thrown, but not onto anything: a flick discards the top card.
            if (st.discarded < depth - 1)
                decks[src] = st.copy(discarded = st.discarded + 1, faceUp = false)
            runner.cardDropped(src, null, animal)
        }
    }

    Column(Modifier.fillMaxSize().padding(20.dp),
           verticalArrangement = Arrangement.spacedBy(18.dp)) {

        // Header
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                when (runner.phase) {
                    TrialRunner.Phase.IDLE -> "Not started"
                    TrialRunner.Phase.DONE -> "Finished"
                    else -> "Scene ${minOf(runner.index + 1, runner.total)} of ${runner.total}"
                },
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
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
                  topOf = ::topOf,
                  showsFaceOf = { stateOf(it).showsFace })
            when {
                quiet?.isOffscreen == true -> Panel(quiet.promptText, big = true)
                quiet?.isWaiting == true ->
                    Panel(quiet.promptText.ifBlank { waitingText }, big = false)
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
    topOf: (Int) -> String,
    showsFaceOf: (Int) -> Boolean
) {
    val gap = if (rows * cols > 9) 10.dp else 16.dp
    val live = runner.current.takeIf {
        runner.phase == TrialRunner.Phase.CUED || runner.phase == TrialRunner.Phase.SETTLING
    }
    val flashing = runner.current.takeIf { runner.phase == TrialRunner.Phase.GAP }
    val big = max(rows, cols)
    val density = LocalDensity.current

    Box(Modifier.fillMaxSize().alpha(if (dimmed) 0.18f else 1f)) {
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
                        Cell(
                            block = b, live = isLive, target = isTarget, flashing = isFlash,
                            big = big, verb = if (isLive) live?.displayVerb else null,
                            animals = animalsOf(b), state = stateOf(b),
                            onState = { onState(b, it) },
                            onEvent = { onEvent(b, it) },
                            carrying = carrying == b,
                            onFrame = { onFrame(b, it) },
                            onDragChanged = { onDragChanged(b, it) },
                            onDragEnded = { tr, pr -> onDragEnded(b, tr, pr) },
                            modifier = Modifier.weight(1f).fillMaxHeight())
                    }
                }
            }
        }

        // The card under the finger, drawn above every block so it can pass over
        // them instead of being clipped by its own cell.
        if (carried != null) {
            val (b, off) = carried
            Box(Modifier.fillMaxSize()) {
                CarriedCard(block = b, animal = topOf(b), faceUp = showsFaceOf(b),
                            offset = off, big = big, density = density)
            }
        }
    }
}

@Composable
private fun CarriedCard(
    block: Int, animal: String, faceUp: Boolean, offset: Offset, big: Int,
    density: androidx.compose.ui.unit.Density
) {
    val side = cardSideFor(big)
    Box(Modifier.fillMaxSize()) {
        CardFace(
            back = DeckBack.forBlock(block), faceUp = faceUp, animal = animal,
            cardSize = side, lifted = true,
            modifier = Modifier
                .align(Alignment.Center)
                .graphicsLayer {
                    translationX = offset.x
                    translationY = offset.y
                })
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
    verb: String?,
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
        flashing -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.18f)
        live -> accent.copy(alpha = 0.16f)
        target -> Color(0xFF2E7D32).copy(alpha = 0.12f)
        else -> Color.Gray.copy(alpha = 0.10f)
    }
    val stroke = when {
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
                width = if (live || flashing) 6.dp else if (target) 5.dp else 2.dp,
                color = stroke, shape = RoundedCornerShape(radius))
            .padding(pad)
            .onGloballyPositioned { onFrame(it.boundsInParent()) },
        contentAlignment = Alignment.Center
    ) {
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
private fun Panel(text: String, big: Boolean) {
    Surface(shape = RoundedCornerShape(if (big) 28.dp else 24.dp), tonalElevation = 6.dp) {
        Text(
            text,
            fontSize = if (big) 40.sp else 44.sp,
            fontWeight = if (big) FontWeight.SemiBold else FontWeight.Light,
            textAlign = TextAlign.Center,
            color = if (big) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 52.dp, vertical = 32.dp).widthIn(max = 760.dp)
        )
    }
}
