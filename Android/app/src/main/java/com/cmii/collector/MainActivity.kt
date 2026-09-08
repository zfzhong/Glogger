package com.cmii.collector

import android.Manifest
import android.os.Bundle
import android.view.WindowManager
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.view.WindowCompat
import kotlinx.coroutines.launch

/**
 * Three screens, in the order a session actually happens: choose the experiment,
 * run it, see what was recorded. The same flow as the iPad, for the same reason -
 * the experiment is the only thing that changes between participants, so it is
 * the first thing on screen rather than buried in settings.
 */
class MainActivity : ComponentActivity() {

    private lateinit var recorder: Recorder
    private lateinit var motion: MotionLogger
    private lateinit var beacon: BleAdvertiser
    private lateinit var config: Config
    private lateinit var server: ServerClient
    private lateinit var uploader: Uploader
    private val runner = TrialRunner()

    private enum class Screen { LIST, CONFIG, RUNNING, SUMMARY }
    private var screen by mutableStateOf(Screen.LIST)
    private var scenesTotal by mutableIntStateOf(0)
    private var uploadState by mutableStateOf("")
    private var uploading by mutableStateOf(false)
    private var counter by mutableIntStateOf(0)   // redraws the live counts

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)
        // The iPad disables its idle timer for a run; without the equivalent here
        // a tablet dozes off mid-scene, the scene times out unanswered, and the
        // session is scored as a string of misses.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        // A study tablet is handed to a participant, so it must come back without
        // anyone typing a PIN when the operator wakes it between runs.
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        recorder = Recorder(this)
        motion = MotionLogger(this)
        beacon = BleAdvertiser(this)
        config = Config(this)
        server = ServerClient(cacheDir)
        uploader = Uploader()

        recorder.onTouchDown = { runner.touchDown(it) }
        recorder.onGesture = { runner.gesture(it) }
        runner.onRow = { recorder.writeTrialRow(it) }
        runner.onDeckRow = { recorder.writeDeckRow(it) }
        runner.onFinished = { finishRun() }

        setContent {
            MaterialTheme {
                val scope = rememberCoroutineScope()
                var experiments by remember { mutableStateOf(listOf<ExperimentInfo>()) }
                var status by remember { mutableStateOf("") }
                var busy by remember { mutableStateOf(false) }
                var failure by remember { mutableStateOf("") }
                var loadingId by remember { mutableStateOf<Int?>(null) }

                val permissions = rememberLauncherForActivityResult(
                    ActivityResultContracts.RequestMultiplePermissions()
                ) { }

                suspend fun refresh() {
                    busy = true
                    val m = resources.displayMetrics
                    // Idempotent, so a tablet named on the web picks that up on the
                    // next refresh rather than needing a restart.
                    server.register(
                        config.serverBase, config.deviceId,
                        android.os.Build.MODEL,
                        "Android ${android.os.Build.VERSION.RELEASE}",
                        "${m.widthPixels}x${m.heightPixels}"
                    )?.let { (name, adv) ->
                        config.deviceName = name
                        if (adv.isNotBlank()) config.advertiseName = adv
                    }
                    val (list, msg) = server.loadExperiments(config.serverBase)
                    experiments = list; status = msg; busy = false
                }

                LaunchedEffect(Unit) {
                    // Asked once, up front, rather than in the middle of a session:
                    // a dialog appearing over the board mid-run would be recorded
                    // as touches and would interrupt the timeline.
                    permissions.launch(arrayOf(
                        Manifest.permission.BLUETOOTH_ADVERTISE,
                        Manifest.permission.BLUETOOTH_CONNECT))
                    refresh()
                }

                Surface(Modifier.fillMaxSize()) {
                    when (screen) {
                        Screen.LIST -> ExperimentListScreen(
                            config = config, server = server, experiments = experiments,
                            status = status, busy = busy, failure = failure,
                            onRefresh = { scope.launch { refresh() } },
                            onConfigure = { screen = Screen.CONFIG },
                            loadingId = loadingId,
                            onStart = { e ->
                                scope.launch {
                                    failure = ""; loadingId = e.id
                                    // Re-measure right before starting: the offset is
                                    // what both tablets' agreement rests on.
                                    server.syncClock(config.serverBase)
                                    val (play, msg) = server.fetchPlay(
                                        config.serverBase, e.id, config.tabletRole)
                                    loadingId = null
                                    if (play == null) { failure = msg; return@launch }
                                    config.experimentId = e.id
                                    config.experimentName = e.name
                                    config.adopt(e)
                                    // The assignment wins over the local picker:
                                    // two tablets can no longer contradict each
                                    // other about which half they are playing.
                                    e.roleFor(config.deviceId)?.let { r ->
                                        config.tabletRole = r
                                        config.followRole()
                                        e.advertiseFor(config.deviceId)
                                            ?.takeIf { it.isNotBlank() }
                                            ?.let { config.advertiseName = it }
                                    }
                                    val late = e.startAtMs?.let {
                                        maxOf(0L, server.serverNowMs() - it).toInt()
                                    } ?: 0
                                    begin(play, late)
                                }
                            })

                        Screen.CONFIG -> ConfigScreen(
                            config = config, beacon = beacon,
                            deviceLine = deviceLine(),
                            onDone = { screen = Screen.LIST; scope.launch { refresh() } })

                        Screen.RUNNING -> Column(Modifier.fillMaxSize()) {
                            RunBar()
                            HorizontalDivider()
                            StudyScreen(runner, runner.play?.waiting ?: "waiting…") { ev, detail ->
                                recorder.writeWebRow(runner.index, ev, detail)
                            }
                        }

                        Screen.SUMMARY -> RunSummaryScreen(
                            recorder = recorder, config = config,
                            scenesDone = runner.nDone, scenesTotal = scenesTotal,
                            uploadState = uploadState, uploading = uploading,
                            onUpload = {
                                scope.launch {
                                    uploading = true
                                    uploadState = uploader.upload(
                                        recorder.csvFiles(), recorder.sessionName,
                                        config.serverBase, config.studyName,
                                        config.participant,
                                        config.uploadToken.ifBlank { null },
                                        config.experimentId) { uploadState = it }
                                    uploading = false
                                }
                            },
                            onDone = {
                                uploadState = ""
                                recorder.sessionName = Recorder.defaultName()
                                screen = Screen.LIST
                                scope.launch { refresh() }
                            })
                    }
                }
            }
        }
    }

    @Composable
    private fun RunBar() {
        Surface(tonalElevation = 3.dp) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (recorder.isRecording) "●" else "○",
                     color = if (recorder.isRecording) Color(0xFFD32F2F) else Color.Gray)
                Text(config.experimentName.ifEmpty { "Session" },
                     style = MaterialTheme.typography.titleSmall)
                Text("Tablet ${config.tabletRole}", style = MaterialTheme.typography.bodySmall)
                beacon.readiness()?.let {
                    // A beacon that is silently off looks exactly like a watch that
                    // is not scanning, and the session is lost before anyone notices.
                    Text(it, style = MaterialTheme.typography.bodySmall, color = Color(0xFFB26A00))
                }
                if (runner.skipped > 0)
                    Text("joined late — ${runner.skipped} missed",
                         style = MaterialTheme.typography.bodySmall, color = Color(0xFFB26A00))
                Spacer(Modifier.weight(1f))
                key(counter) {
                    Text("touch ${recorder.nTaps}  gest ${recorder.nGestures}  " +
                         "BLE ${recorder.nBle}  IMU ${recorder.nImu}",
                         fontFamily = FontFamily.Monospace,
                         style = MaterialTheme.typography.bodySmall)
                }
                Button(onClick = { finishRun() }) {
                    Text(if (runner.isRunning) "Stop" else "End session")
                }
            }
        }
    }

    private fun deviceLine(): String {
        val m = resources.displayMetrics
        return "${android.os.Build.MODEL} · ${m.widthPixels}x${m.heightPixels} · " +
               "${m.densityDpi} dpi · Android ${android.os.Build.VERSION.RELEASE}"
    }

    private fun begin(play: Play, joinedLateMs: Int) {
        scenesTotal = play.trials.size
        uploadState = ""
        recorder.start()
        motion.start(recorder)
        // Only the tablet designated as the beacon advertises. Both advertising
        // under one name would put two devices behind a single label in the
        // watch's log, with no way to separate them afterwards.
        if (config.advertise) beacon.start(config.advertiseName)
        val m = resources.displayMetrics
        recorder.writeSessionFiles(play, SessionMeta(
            experimentId = config.experimentId, experimentName = config.experimentName,
            advertiseName = config.advertiseName, participant = config.participant,
            studyName = config.studyName, watchWrist = config.watchWrist,
            interactingHand = config.interactingHand, posture = config.posture,
            tabletOrientation = config.tabletOrientation, tabletRole = config.tabletRole,
            advertised = config.advertise,
            serverClockOffsetMs = server.clockOffsetMs,
            serverClockMeasured = server.clockKnown, joinedLateMs = joinedLateMs,
            playJson = "{}", screenWidthPx = m.widthPixels,
            screenHeightPx = m.heightPixels, densityDpi = m.densityDpi))
        runner.start(play, joinedLateMs)
        screen = Screen.RUNNING
    }

    private fun finishRun() {
        if (screen != Screen.RUNNING) return
        runner.abort()
        beacon.stop(); motion.stop(); recorder.stop()
        screen = Screen.SUMMARY
    }

    /** Observes, never consumes: the event is always passed on to the view tree. */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        recorder.ingest(ev)
        if (ev.actionMasked == MotionEvent.ACTION_UP) counter++
        return super.dispatchTouchEvent(ev)
    }

    override fun onDestroy() {
        super.onDestroy()
        beacon.stop(); motion.stop(); recorder.stop()
    }
}
