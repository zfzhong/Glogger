package com.cmii.collector

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/* ── Landing ─────────────────────────────────────────────────────────────── */

/**
 * Pick the experiment this participant is about to run.
 *
 * Same shape as the iPad's landing screen, and for the same reasons: the
 * experiment is the one thing that changes every session, so it is the first
 * screen rather than three taps into settings; experiments that cannot run are
 * shown greyed WITH the reason rather than hidden, because one that simply
 * vanishes looks like it was never created.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExperimentListScreen(
    config: Config,
    server: ServerClient,
    experiments: List<ExperimentInfo>,
    status: String,
    busy: Boolean,
    failure: String,
    onRefresh: () -> Unit,
    onConfigure: () -> Unit,
    onStart: (ExperimentInfo) -> Unit,
    loadingId: Int?
) {
    // Keeps the countdowns honest without the operator pulling to refresh.
    var tick by remember { mutableLongStateOf(0L) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }

    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Choose an experiment", fontSize = 30.sp, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.weight(1f))
                if (busy) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                else TextButton(onClick = onRefresh) { Text("Refresh") }
                TextButton(onClick = onConfigure) { Text("Configure") }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(18.dp),
                verticalAlignment = Alignment.CenterVertically) {
                // Which tablet this is. Both download the same play and follow the
                // same timeline; the role decides whose scenes are whose.
                // No role picker: the server assigns tablets, and a control that
                // could contradict it is just a way to be wrong.
                Text(config.deviceName.ifBlank { "unnamed tablet" },
                     style = MaterialTheme.typography.titleMedium,
                     color = if (config.deviceName.isBlank()) warn()
                             else MaterialTheme.colorScheme.onSurface)
                Text(config.advertiseName, fontFamily = FontFamily.Monospace,
                     style = MaterialTheme.typography.bodyMedium,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(status, style = MaterialTheme.typography.bodySmall,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                if (server.clockKnown && Math.abs(server.clockOffsetMs) >= 1000)
                    Text("tablet clock off by ${server.clockOffsetMs / 1000}s — using server time",
                         style = MaterialTheme.typography.bodySmall, color = warn())
                if (failure.isNotEmpty())
                    Text(failure, style = MaterialTheme.typography.bodySmall, color = warn())
            }
        }
        HorizontalDivider()

        // Only what this tablet can actually run: assigned to it, by name. An
        // experiment with no device assigned is not ready, and one assigned to the
        // other tablet is not this tablet's - both are noise at the bench.
        val deviceId = config.deviceId
        val mine = experiments.filter { it.resolvedRole(deviceId) != null }
        val hidden = experiments.size - mine.size

        if (mine.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(if (busy) "Loading…"
                         else if (hidden > 0) "Nothing assigned to this tablet"
                         else "No experiments",
                         style = MaterialTheme.typography.titleMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (hidden > 0 && !busy)
                        Text("$hidden not assigned to this tablet",
                             style = MaterialTheme.typography.bodySmall,
                             color = MaterialTheme.colorScheme.outline)
                }
            }
        } else {
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                items(mine, key = { it.id }) { e ->
                    ExperimentRow(e, server, deviceId, tick, loadingId) { onStart(e) }
                }
                if (hidden > 0) item {
                    // Never silently: an experiment that is simply misassigned
                    // would otherwise look like it was never created.
                    Text("$hidden experiment${if (hidden == 1) "" else "s"} " +
                         "hidden — assigned elsewhere, or no tablet assigned yet",
                         style = MaterialTheme.typography.bodySmall,
                         color = MaterialTheme.colorScheme.outline,
                         modifier = Modifier.padding(top = 6.dp))
                }
            }
        }
    }
}

@Composable
private fun ExperimentRow(
    e: ExperimentInfo,
    server: ServerClient,
    deviceId: String,
    @Suppress("UNUSED_PARAMETER") tick: Long,
    loadingId: Int?,
    onStart: () -> Unit
) {
    // A two-tablet play REQUIRES a scheduled instant: it is the session's zero
    // and the only thing keeping the pair in step. A one-tablet play has nothing
    // to stay in step with, so a time is optional there - and still honoured.
    val startAt = e.startAtMs
    // An assigned experiment names its tablets. This one may not be either of
    // them - the operator has picked up the wrong tablet, or it was never
    // assigned - and running it anyway would file the session under a role it
    // does not have.
    val role = e.resolvedRole(deviceId)
    // A future start time no longer disables the button, it changes what the
    // button does: the tablet arms and waits on a countdown. Disabling it meant
    // the only possible outcome was joining late, which is what the "not_run"
    // rows were compensating for. Both tablets can now be set going in advance
    // by one pair of hands and still begin on the same instant.
    val canStart = e.hasPlay && role != null

    Surface(
        shape = RoundedCornerShape(12.dp),
        tonalElevation = 2.dp,
        modifier = Modifier.fillMaxWidth().alpha(if (e.hasPlay) 1f else 0.62f)
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(e.name, style = MaterialTheme.typography.titleMedium,
                     fontWeight = FontWeight.SemiBold)
                if (e.description.isNotEmpty())
                    Text(e.description, style = MaterialTheme.typography.bodyMedium,
                         color = MaterialTheme.colorScheme.onSurfaceVariant,
                         maxLines = 2, overflow = TextOverflow.Ellipsis)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    if (e.hasPlay) {
                        Text(e.playName ?: "play", style = MaterialTheme.typography.bodySmall)
                        Text("${e.trialCount} scenes", style = MaterialTheme.typography.bodySmall)
                        if (e.totalMs > 0) Text(e.durationText,
                                                style = MaterialTheme.typography.bodySmall)
                        if (e.tablets > 1) Text("2 tablets",
                                                style = MaterialTheme.typography.bodySmall)
                    } else {
                        Text(e.blockedReason, style = MaterialTheme.typography.bodySmall,
                             color = warn())
                    }
                }
                if (role != null) {
                    val beacons = e.advertisesFor(deviceId)
                    Text(if (e.tablets > 1)
                             "plays $role · " + (if (beacons) "beacon" else "decoy, silent")
                         else "beacon",
                         style = MaterialTheme.typography.bodySmall, color = good())
                }
                if (e.missing.isNotEmpty())
                    Text("not described on the server: " + e.missing.joinToString(", "),
                         style = MaterialTheme.typography.bodySmall, color = warn())
                if (e.sessions > 0)
                    Text("${e.sessions} session${if (e.sessions == 1) "" else "s"} already collected",
                         style = MaterialTheme.typography.bodySmall,
                         color = MaterialTheme.colorScheme.outline)
            }

            Spacer(Modifier.width(12.dp))

            if (loadingId == e.id) {
                CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
            } else {
                Column(horizontalAlignment = Alignment.End,
                       verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Button(onClick = onStart, enabled = canStart && loadingId == null) {
                        Text("Start")
                    }
                    if (startAt != null) {
                        Text(clockText.format(Date(startAt)),
                             style = MaterialTheme.typography.bodySmall,
                             fontFamily = FontFamily.Monospace)
                        Text(countdown(startAt, server.serverNowMs()),
                             style = MaterialTheme.typography.bodySmall,
                             color = if (canStart) good() else MaterialTheme.colorScheme.onSurfaceVariant)
                        if (server.serverNowMs() < startAt)
                            Text("tap now to wait for it",
                                 style = MaterialTheme.typography.bodySmall,
                                 color = MaterialTheme.colorScheme.outline)
                    } else if (e.tablets > 1) {
                        Text("two tablets — needs a start time",
                             style = MaterialTheme.typography.bodySmall,
                             color = warn(), textAlign = TextAlign.End)
                    } else {
                        Text("starts when you tap", style = MaterialTheme.typography.bodySmall,
                             color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

private val clockText = SimpleDateFormat("HH:mm:ss", Locale.US)

private fun countdown(at: Long, now: Long): String {
    val secs = ((at - now) / 1000.0).toInt()
    if (secs <= 0) {
        val ago = -secs
        return when {
            ago < 2 -> "now"
            ago < 90 -> "running ${ago}s"
            ago < 5400 -> "running ${ago / 60} min"
            else -> "began ${ago / 3600} h ago"
        }
    }
    return when {
        secs < 90 -> "starts in ${secs}s"
        secs < 5400 -> "starts in ${secs / 60} min"
        else -> "starts in ${secs / 3600} h"
    }
}

@Composable private fun warn() = Color(0xFFB26A00)
@Composable private fun good() = Color(0xFF1B7A55)

/* ── Summary ─────────────────────────────────────────────────────────────── */

/**
 * What was actually recorded, shown before the participant leaves the chair.
 *
 * A session that recorded nothing is cheap to repeat while the person is still
 * sitting there and impossible afterwards, so every stream is listed with its
 * count and an empty one is called out rather than left to be noticed later.
 */
@Composable
fun RunSummaryScreen(
    recorder: Recorder,
    config: Config,
    scenesDone: Int,
    scenesTotal: Int,
    uploadState: String,
    uploading: Boolean,
    onUpload: () -> Unit,
    onDone: () -> Unit
) {
    val channels = listOf(
        Triple("Touches", recorder.nTaps, true),
        Triple("Gestures", recorder.nGestures, false),
        Triple("BLE", recorder.nBle, false),
        Triple("IMU", recorder.nImu, true)
    )
    val problems = buildList {
        channels.filter { it.second == 0 && it.third }
            .forEach { add("${it.first.lowercase()} recorded nothing") }
        if (scenesTotal > 0 && scenesDone < scenesTotal)
            add("stopped after $scenesDone of $scenesTotal scenes")
    }

    Column(
        Modifier.fillMaxSize().padding(34.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(24.dp)
    ) {
        Spacer(Modifier.height(20.dp))
        Text(if (problems.isEmpty()) "Session recorded" else "Session recorded, with gaps",
             fontSize = 28.sp, fontWeight = FontWeight.SemiBold,
             color = if (problems.isEmpty()) MaterialTheme.colorScheme.onSurface else warn())
        Text(recorder.sessionName, fontFamily = FontFamily.Monospace,
             color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (config.experimentName.isNotEmpty())
            Text(config.experimentName, color = MaterialTheme.colorScheme.onSurfaceVariant)

        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            channels.forEach { (name, n, _) -> Tile(name, "$n", n == 0) }
            Tile("Scenes", "$scenesDone/$scenesTotal", false)
        }

        problems.forEach {
            Text("• $it", color = warn(), style = MaterialTheme.typography.bodyLarge)
        }
        if (uploadState.isNotEmpty())
            Text(uploadState, color = if (uploadState.contains("FAILED")) warn()
                                      else MaterialTheme.colorScheme.onSurfaceVariant)

        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Button(onClick = onUpload, enabled = !uploading) {
                Text(if (uploading) "Uploading…" else "Upload")
            }
            OutlinedButton(onClick = onDone, enabled = !uploading) {
                Text(if (uploadState.isEmpty()) "Done without uploading" else "Done")
            }
        }
    }
}

@Composable
private fun Tile(label: String, value: String, empty: Boolean) {
    Surface(shape = RoundedCornerShape(10.dp), tonalElevation = 2.dp) {
        Column(Modifier.padding(horizontal = 22.dp, vertical = 12.dp),
               horizontalAlignment = Alignment.CenterHorizontally) {
            Text(value, fontFamily = FontFamily.Monospace, fontSize = 22.sp,
                 color = if (empty) warn() else MaterialTheme.colorScheme.onSurface)
            Text(label, style = MaterialTheme.typography.bodySmall,
                 color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
