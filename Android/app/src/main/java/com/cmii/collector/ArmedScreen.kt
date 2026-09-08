package com.cmii.collector

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.max

/**
 * The wait between arming a tablet and its scheduled start.
 *
 * Two tablets have to begin on the same instant, and one pair of hands cannot
 * press two buttons simultaneously. So the button no longer waits for the
 * instant - it arms the tablet, and the instant is what starts the play.
 *
 * The countdown is computed from the SERVER clock, not this device's. Two
 * tablets counting down on their own clocks would still start as far apart as
 * their clocks are wrong, which is the whole problem restated rather than
 * solved.
 *
 * The board is shown behind, dimmed, but without the first scene's cue. Showing
 * the decks tells the participant where to look; showing "swipe left" for ten
 * seconds lets them pre-position their hand, and scene 1 stops being comparable
 * to scene 8.
 */
@Composable
fun ArmedScreen(
    play: Play,
    experimentName: String,
    remainingMs: Long,
    recording: Boolean,
    clockKnown: Boolean,
    onCancel: () -> Unit
) {
    Column(Modifier.fillMaxSize()) {
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (recording) "●" else "○",
                     color = if (recording) androidx.compose.ui.graphics.Color(0xFFD32F2F)
                             else androidx.compose.ui.graphics.Color.Gray)
                Text(experimentName.ifEmpty { "Session" },
                     style = MaterialTheme.typography.titleSmall)
                Text(if (recording) "recording — waiting for the start"
                     else "armed, waiting for the start",
                     style = MaterialTheme.typography.bodySmall,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (!clockKnown)
                    // Without a measured offset the countdown is only as good as
                    // this tablet's own clock, and two tablets can drift apart by
                    // more than a scene lasts.
                    Text("server clock not measured — start may be off",
                         style = MaterialTheme.typography.bodySmall,
                         color = androidx.compose.ui.graphics.Color(0xFFB26A00))
                Spacer(Modifier.weight(1f))
                // Picking the wrong experiment on one of two tablets should not
                // need a force-quit to undo.
                OutlinedButton(onClick = onCancel) { Text("Cancel") }
            }
        }
        HorizontalDivider()

        Box(Modifier.fillMaxSize().padding(20.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.fillMaxSize().alpha(0.18f)) {
                StaticBoard(rows = play.rows, cols = play.cols,
                            pool = play.blockPictures.ifEmpty { Animals.all })
            }
            Surface(shape = RoundedCornerShape(28.dp), tonalElevation = 6.dp) {
                Column(
                    Modifier.padding(horizontal = 64.dp, vertical = 36.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    Text("Starting in", style = MaterialTheme.typography.titleMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(clock(remainingMs), fontSize = 84.sp,
                         fontWeight = FontWeight.Light,
                         fontFamily = FontFamily.Monospace,
                         textAlign = TextAlign.Center)
                    Text("Please hold still until the board lights up.",
                         style = MaterialTheme.typography.bodyLarge,
                         color = MaterialTheme.colorScheme.onSurfaceVariant,
                         textAlign = TextAlign.Center)
                }
            }
        }
    }
}

/** m:ss, floored at zero so the last tick reads 0:00 rather than a negative. */
fun clock(ms: Long): String {
    val total = max(0L, ms + 999) / 1000        // round up: 0.4s left is still "1"
    return "%d:%02d".format(total / 60, total % 60)
}
