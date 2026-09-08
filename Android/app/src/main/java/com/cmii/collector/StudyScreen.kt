package com.cmii.collector

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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The cue screen.
 *
 * One block is live at a time; the rest stay visible so the layout - and
 * therefore the reach distances - stay constant. The grid is whatever the scene
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
    Board(runner, waitingText)
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
private fun Board(runner: TrialRunner, waitingText: String) {
    val t = runner.displayTrial
    val play = runner.play
    val rows = t?.rows ?: play?.rows ?: 2
    val cols = t?.cols ?: play?.cols ?: 2

    val quiet: Trial? = runner.current?.takeIf {
        (it.isWaiting || it.isOffscreen) &&
            runner.phase in listOf(TrialRunner.Phase.READY, TrialRunner.Phase.CUED,
                                   TrialRunner.Phase.SETTLING)
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
            Grid(rows, cols, runner, dimmed = quiet != null)
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
private fun Grid(rows: Int, cols: Int, runner: TrialRunner, dimmed: Boolean) {
    val gap = if (rows * cols > 9) 10.dp else 16.dp
    val live = runner.current.takeIf {
        runner.phase == TrialRunner.Phase.CUED || runner.phase == TrialRunner.Phase.SETTLING
    }
    Column(
        Modifier.fillMaxSize().alpha(if (dimmed) 0.18f else 1f),
        verticalArrangement = Arrangement.spacedBy(gap)
    ) {
        for (r in 0 until rows) {
            Row(Modifier.fillMaxWidth().weight(1f),
                horizontalArrangement = Arrangement.spacedBy(gap)) {
                for (c in 0 until cols) {
                    // A freeform scene still carries a row and column, but lighting
                    // a deck would contradict a screen that says to do something
                    // else - or nothing at all.
                    val isLive = live != null && !live.isFreeform &&
                                 live.row == r && live.col == c
                    val isTarget = live?.isTravelling == true &&
                                   live.toRow == r && live.toCol == c
                    Deck(index = r * cols + c, live = isLive, target = isTarget,
                         modifier = Modifier.weight(1f).fillMaxHeight())
                }
            }
        }
    }
}

/**
 * A block. The colour is deterministic from its position so the board looks the
 * same on both tablets and across sessions - a participant should not be
 * relearning the layout every run.
 */
@Composable
private fun Deck(index: Int, live: Boolean, target: Boolean, modifier: Modifier = Modifier) {
    val hues = listOf(0.02f, 0.09f, 0.14f, 0.33f, 0.52f, 0.58f, 0.72f, 0.85f, 0.95f)
    val hue = hues[index % hues.size]
    val base = Color.hsl(hue * 360f, 0.35f, 0.72f)
    Box(
        modifier
            .clip(RoundedCornerShape(18.dp))
            .background(if (live) base else base.copy(alpha = 0.45f))
            .border(
                width = if (live) 5.dp else if (target) 3.dp else 1.dp,
                color = when {
                    live -> Color(0xFF1B7A55)
                    target -> Color(0xFF2A6FB0)
                    else -> Color.Black.copy(alpha = 0.10f)
                },
                shape = RoundedCornerShape(18.dp)
            ),
        contentAlignment = Alignment.Center
    ) {
        if (target) Text("here", color = Color(0xFF2A6FB0), fontWeight = FontWeight.SemiBold)
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
