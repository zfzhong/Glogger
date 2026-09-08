package com.cmii.collector

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * The operator's settings.
 *
 * The experiment is NOT here - it changes every session and lives on the landing
 * screen. Nor is the sitting: participant, wrist, hand, posture and orientation
 * are set on the experiment, on the server, so two tablets cannot describe the
 * same session differently. They are shown read-only for confirmation.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConfigScreen(
    config: Config,
    beacon: BleAdvertiser,
    deviceLine: String,
    onDone: () -> Unit
) {
    var server by remember { mutableStateOf(config.serverBase) }
    var token by remember { mutableStateOf(config.uploadToken) }
    var advName by remember { mutableStateOf(config.advertiseName) }
    var advertise by remember { mutableStateOf(config.advertise) }
    var study by remember { mutableStateOf(config.studyName) }
    var role by remember { mutableStateOf(config.tabletRole) }

    fun save() {
        config.serverBase = server.trim()
        config.uploadToken = token.trim()
        config.advertiseName = advName.trim().ifEmpty { "CMII-Pad" }
        config.advertise = advertise
        config.studyName = study.trim()
        config.tabletRole = role
    }

    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(20.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text("Configuration", fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Button(onClick = { save(); onDone() }) { Text("Done") }
        }
        HorizontalDivider()

        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp)
        ) {
            Section("Server") {
                OutlinedTextField(
                    value = server, onValueChange = { server = it },
                    label = { Text("https://host") }, singleLine = true,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = KeyboardType.Uri, imeAction = ImeAction.Next),
                    modifier = Modifier.fillMaxWidth())
                OutlinedTextField(
                    value = token, onValueChange = { token = it },
                    label = { Text("upload token (optional)") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth())
            }

            Section("This tablet") {
                SingleChoiceSegmentedButtonRow {
                    listOf("A", "B").forEachIndexed { i, r ->
                        SegmentedButton(
                            selected = role == r,
                            onClick = {
                                role = r
                                // Only B is the beacon; A is the decoy whose taps
                                // must look far from it.
                                advertise = (r == "B")
                            },
                            shape = SegmentedButtonDefaults.itemShape(i, 2)
                        ) { Text("Tablet $r") }
                    }
                }
                Hint("Which half of a two-tablet play this tablet runs. Both " +
                     "download the same play; the role decides whose scenes are whose.")
                Text(deviceLine, fontFamily = FontFamily.Monospace,
                     style = MaterialTheme.typography.bodySmall,
                     color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            Section("Beacon") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Switch(checked = advertise, onCheckedChange = { advertise = it })
                    Spacer(Modifier.width(12.dp))
                    Text(if (advertise) "This tablet advertises" else "Not advertising")
                }
                OutlinedTextField(
                    value = advName, onValueChange = { advName = it },
                    label = { Text("advertise name") }, singleLine = true,
                    enabled = advertise, modifier = Modifier.fillMaxWidth())
                Hint("The watch scans for this EXACT name — Slogger's filter is an " +
                     "exact match, so CMII-Pad-1 will not match CMII-Pad.")
                // Two tablets advertising the same name is indistinguishable at the
                // watch: every sample would be attributed to whichever it matched.
                Hint("Tablet B is the beacon; Tablet A stays silent. Tapping A looks " +
                     "identical at the wrist, and the only thing separating it from " +
                     "tapping B is that the wrist stayed far from the beacon — so a " +
                     "silent Tablet A is the measurement, not an omission.")
                if ((role == "B" && !advertise) || (role == "A" && advertise))
                    Hint(if (role == "A")
                             "Tablet A is set to advertise. Two beacons would erase the " +
                             "contrast between tapping A and tapping B."
                         else
                             "Tablet B is not advertising. The watch will see no beacon " +
                             "at all this session.", warn = true)
                beacon.readiness()?.let {
                    Text("Beacon cannot start: $it", color = Color(0xFFB26A00),
                         style = MaterialTheme.typography.bodyMedium)
                }
            }

            Section("Session") {
                OutlinedTextField(
                    value = study, onValueChange = { study = it },
                    label = { Text("study") }, singleLine = true,
                    modifier = Modifier.fillMaxWidth())
                ReadOnly("Participant", config.participant)
                ReadOnly("Watch wrist", config.watchWrist)
                ReadOnly("Interacting hand", config.interactingHand)
                ReadOnly("Posture", config.posture)
                ReadOnly("Tablet orientation", config.tabletOrientation)
                Hint("Set on the experiment, on the server. This tablet adopts them " +
                     "when a run starts, so two tablets cannot disagree about the " +
                     "same sitting.")
            }

            Spacer(Modifier.height(30.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium,
             fontWeight = FontWeight.SemiBold)
        content()
    }
}

@Composable
private fun Hint(text: String, warn: Boolean = false) {
    Text(text, style = MaterialTheme.typography.bodySmall,
         color = if (warn) Color(0xFFB26A00) else MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ReadOnly(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Spacer(Modifier.weight(1f))
        Text(value.ifBlank { "—" }, fontFamily = FontFamily.Monospace,
             color = if (value.isBlank()) MaterialTheme.colorScheme.outline
                     else MaterialTheme.colorScheme.onSurface)
    }
}
