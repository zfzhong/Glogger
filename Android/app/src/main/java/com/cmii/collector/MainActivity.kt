package com.cmii.collector

import android.Manifest
import android.os.Bundle
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

/**
 * TEMPORARY harness while the capture layer is built.
 *
 * It exists so every stream can be exercised from adb before any real screen
 * exists - taps and swipes through `input`, then the CSVs pulled back and
 * checked. The landing list, study view and summary replace all of this.
 *
 * Touch capture is the one place Android is plainly better than iOS: an activity
 * sees every touch delivered anywhere in the app through dispatchTouchEvent,
 * including over a WebView, with pressure and size already on the event, and
 * passes it on afterwards rather than needing a recognizer that promises not to
 * consume anything.
 */
class MainActivity : ComponentActivity() {

    private lateinit var recorder: Recorder
    private lateinit var motion: MotionLogger
    private lateinit var beacon: BleAdvertiser
    private lateinit var config: Config
    private lateinit var server: ServerClient

    private var tick by mutableIntStateOf(0)
    private var note by mutableStateOf("")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        recorder = Recorder(this)
        motion = MotionLogger(this)
        beacon = BleAdvertiser(this)
        config = Config(this)
        server = ServerClient(cacheDir)

        setContent {
            MaterialTheme {
                val scope = rememberCoroutineScope()
                val ask = rememberLauncherForActivityResult(
                    ActivityResultContracts.RequestMultiplePermissions()
                ) { }
                Surface(Modifier.fillMaxSize()) {
                    Column(
                        Modifier.fillMaxSize().padding(28.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(14.dp)
                    ) {
                        Text("GestureLogger", style = MaterialTheme.typography.headlineMedium)
                        key(tick) {
                            Text(recorder.status, fontFamily = FontFamily.Monospace)
                            Text("touches ${recorder.nTaps}   gestures ${recorder.nGestures}   " +
                                 "IMU ${recorder.nImu}   BLE ${recorder.nBle}",
                                 fontFamily = FontFamily.Monospace)
                            Text("beacon: " + (beacon.readiness()
                                ?: if (beacon.advertising) "advertising as ${config.advertiseName}"
                                   else "ready"),
                                 fontFamily = FontFamily.Monospace)
                        }
                        if (note.isNotEmpty()) Text(note, fontFamily = FontFamily.Monospace)

                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            Button(onClick = {
                                ask.launch(arrayOf(Manifest.permission.BLUETOOTH_ADVERTISE,
                                                   Manifest.permission.BLUETOOTH_CONNECT,
                                                   Manifest.permission.BLUETOOTH_SCAN))
                            }) { Text("Permissions") }

                            Button(onClick = {
                                recorder.start()
                                motion.start(recorder)
                                beacon.start(config.advertiseName)
                                tick++
                            }) { Text("Start") }

                            Button(onClick = {
                                beacon.stop(); motion.stop(); recorder.stop(); tick++
                            }) { Text("Stop") }

                            Button(onClick = {
                                scope.launch {
                                    val (list, msg) = server.loadExperiments(config.serverBase)
                                    note = "$msg · offset ${server.clockOffsetMs} ms · " +
                                           "${list.count { it.hasPlay }} runnable"
                                    tick++
                                }
                            }) { Text("Server") }
                        }
                        Spacer(Modifier.weight(1f))
                        Text("touch anywhere below — every pointer is recorded",
                             style = MaterialTheme.typography.bodySmall)
                        Spacer(Modifier.weight(1f))
                    }
                }
            }
        }
    }

    /** Observes, never consumes: the event is always passed on to the view tree. */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        recorder.ingest(ev)
        if (ev.actionMasked == MotionEvent.ACTION_UP) tick++
        return super.dispatchTouchEvent(ev)
    }

    override fun onDestroy() {
        super.onDestroy()
        beacon.stop(); motion.stop(); recorder.stop()
    }
}
