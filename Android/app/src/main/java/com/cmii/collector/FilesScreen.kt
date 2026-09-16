package com.cmii.collector

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File

/**
 * Every session the tablet has ever recorded, and a way to send one again.
 *
 * Sessions are never deleted, so the tablet holds the only copy of anything
 * that failed to upload. Until this screen existed there was no way back to
 * one: the summary appeared once, and dismissing it - or an upload that
 * silently did nothing - stranded the session where only a developer machine
 * could reach it. A family's living room does not have one of those.
 *
 * Uploading is idempotent: the server keys on (session, filename, sha256), so
 * sending a session twice costs bandwidth and nothing else, and a partly failed
 * upload is repaired by sending the whole thing again.
 */
@Composable
fun FilesScreen(root: File, config: Config, onBack: () -> Unit) {
    val scope = rememberCoroutineScope()
    val uploader = remember { Uploader() }
    var sessions by remember { mutableStateOf(sessionFolders(root)) }
    var chosen by remember { mutableStateOf<SessionFolder?>(null) }
    var progress by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }

    val here = chosen

    Column(Modifier.fillMaxSize().padding(20.dp),
           verticalArrangement = Arrangement.spacedBy(12.dp)) {

        Row(verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = { if (here == null) onBack() else { chosen = null; progress = "" } }) {
                Text("< Back")
            }
            Text(here?.name ?: "Files",
                 fontSize = 26.sp, fontWeight = FontWeight.SemiBold,
                 modifier = Modifier.padding(start = 6.dp))
            Spacer(Modifier.weight(1f))
            if (here != null) {
                if (busy) CircularProgressIndicator(Modifier.size(22.dp), strokeWidth = 2.dp)
                else Button(onClick = {
                    scope.launch {
                        busy = true
                        // Settings come from the session's own _session.json
                        // where it has them. A run recorded last week under a
                        // different participant must not be uploaded under
                        // today's config - the folder is a snapshot of what was
                        // actually run, and that is what should reach the server.
                        progress = uploader.upload(
                            here.files, here.name, config.serverBase,
                            here.meta.optString("study", config.studyName),
                            here.meta.optString("participant", config.participant),
                            config.uploadToken.ifBlank { null },
                            here.meta.optInt("experiment_id", 0),
                            config.deviceId,
                            here.meta.optString("tablet_role", "")) { progress = it }
                        busy = false
                    }
                }) { Text("Upload") }
            }
        }

        if (progress.isNotEmpty()) {
            // The status line used to live only on the run summary and vanished
            // with it, so a failed upload left no trace of why.
            Text(progress, color = MaterialTheme.colorScheme.primary)
        }

        if (here == null) {
            if (sessions.isEmpty()) {
                Text("No sessions recorded yet.",
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(sessions, key = { it.name }) { s ->
                        Card(Modifier.fillMaxWidth().clickable { chosen = s; progress = "" }) {
                            Column(Modifier.padding(14.dp),
                                   verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(s.name, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)
                                Text("${s.files.size} files  ·  ${human(s.bytes)}" +
                                     (s.meta.optString("experiment_name").takeIf { it.isNotBlank() }
                                        ?.let { "  ·  $it" } ?: ""),
                                     fontSize = 13.sp,
                                     color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                        }
                    }
                }
            }
        } else {
            Text("${here.files.size} files  ·  ${human(here.bytes)}",
                 fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
            LazyColumn(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                items(here.files, key = { it.name }) { f ->
                    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Text(f.name, fontFamily = FontFamily.Monospace, fontSize = 13.sp)
                        Spacer(Modifier.weight(1f))
                        Text(human(f.length()), fontSize = 12.sp,
                             color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    HorizontalDivider()
                }
            }
        }
    }

    // Re-scan whenever the screen comes back into view: a run finished since the
    // last look should be here.
    LaunchedEffect(chosen) { if (chosen == null) sessions = sessionFolders(root) }
}

data class SessionFolder(
    val dir: File,
    val name: String,
    val files: List<File>,
    val meta: JSONObject
) {
    val bytes: Long get() = files.sumOf { it.length() }
}

/** Newest first: the one you are looking for is almost always the last run. */
fun sessionFolders(root: File): List<SessionFolder> {
    val base = File(root, "sessions")
    val dirs = base.listFiles { f: File -> f.isDirectory } ?: return emptyList()
    return dirs.map { d ->
        val files = (d.listFiles { f: File ->
            f.name.endsWith(".csv") || f.name.endsWith(".json")
        } ?: emptyArray()).sortedBy { it.name }
        val metaFile = File(d, "${d.name}_session.json")
        val meta = runCatching { JSONObject(metaFile.readText()) }.getOrDefault(JSONObject())
        SessionFolder(d, d.name, files, meta)
    }.sortedByDescending { it.name }
}

private fun human(n: Long): String = when {
    n >= 1_000_000 -> "%.1f MB".format(n / 1_000_000.0)
    n >= 1_000 -> "%.0f KB".format(n / 1_000.0)
    else -> "$n B"
}
