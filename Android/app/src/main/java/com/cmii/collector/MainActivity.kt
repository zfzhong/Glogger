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

    private enum class Screen { LIST, CONFIG, FILES, ARMED, RUNNING, SUMMARY }
    private var screen by mutableStateOf(Screen.LIST)
    private var scenesTotal by mutableIntStateOf(0)
    private var uploadState by mutableStateOf("")
    private var uploading by mutableStateOf(false)
    private var counter by mutableIntStateOf(0)   // redraws the live counts

    /** The play downloaded and waiting for its scheduled instant. */
    private var armedPlay: Play? = null
    private var armedStartAt = 0L
    private var armedRemainingMs by mutableStateOf(0L)

    companion object {
        /**
         * How long before the start the recorder and beacon come up.
         *
         * Not at the instant itself: the watch has to find the beacon before it
         * can log anything, and a beacon that starts when scene 1 does costs
         * the first seconds of the only signal that says which tablet was
         * touched. Not at arming either - a tablet armed twenty minutes early
         * would write twenty minutes of IMU before the session begins.
         */
        const val PREROLL_MS = 10_000L
    }

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
                    val (sw, sh) = screenPx()
                    // Idempotent, so a tablet named on the web picks that up on the
                    // next refresh rather than needing a restart.
                    server.register(
                        config.serverBase, config.deviceId,
                        android.os.Build.MODEL,
                        "Android ${android.os.Build.VERSION.RELEASE}",
                        "${sw}x$sh"
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
                            onFiles = { screen = Screen.FILES },
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
                                    // The server decides the role; an unassigned
                                    // single-tablet run has no decoy, so this tablet
                                    // is the beacon.
                                    val r = e.resolvedRole(config.deviceId) ?: "B"
                                    config.tabletRole = r
                                    // The experiment says which tablet is the
                                    // beacon; the letter no longer decides it.
                                    config.advertise = e.advertisesFor(config.deviceId)
                                    e.advertiseFor(config.deviceId)
                                        ?.takeIf { it.isNotBlank() }
                                        ?.let { config.advertiseName = it }
                                    val startAt = e.startAtMs
                                    if (startAt != null && server.serverNowMs() < startAt) {
                                        // Still ahead of the instant: hold the
                                        // play and let the clock start it, so two
                                        // tablets set going by one pair of hands
                                        // still begin together.
                                        arm(play, startAt)
                                    } else {
                                        val late = startAt?.let {
                                            maxOf(0L, server.serverNowMs() - it).toInt()
                                        } ?: 0
                                        begin(play, late)
                                    }
                                }
                            })

                        Screen.CONFIG -> ConfigScreen(
                            config = config, beacon = beacon,
                            deviceLine = deviceLine(),
                            onDone = { screen = Screen.LIST; scope.launch { refresh() } })

                        Screen.FILES -> FilesScreen(
                            root = filesDir, config = config,
                            onBack = { screen = Screen.LIST })

                        Screen.ARMED -> {
                            val p = armedPlay
                            if (p == null) { screen = Screen.LIST }
                            else {
                                // One tick per 100 ms rather than per second: the
                                // start has to land on the instant, not on
                                // whenever this tablet's second happened to roll
                                // over, or two tablets are up to a second apart.
                                LaunchedEffect(armedStartAt) {
                                    while (screen == Screen.ARMED) {
                                        val left = armedStartAt - server.serverNowMs()
                                        armedRemainingMs = left
                                        if (left <= PREROLL_MS && !recorder.isRecording)
                                            startRecording(p)
                                        if (left <= 0L) { beginArmed(p); break }
                                        kotlinx.coroutines.delay(100)
                                    }
                                }
                                ArmedScreen(
                                    play = p, experimentName = config.experimentName,
                                    remainingMs = armedRemainingMs,
                                    recording = recorder.isRecording,
                                    clockKnown = server.clockKnown,
                                    onCancel = { cancelArmed() })
                            }
                        }

                        Screen.RUNNING -> Column(Modifier.fillMaxSize()) {
                            RunBar()
                            HorizontalDivider()
                            StudyScreen(runner, runner.play?.waiting ?: "Please read the other Device") { ev, detail ->
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
                                        config.experimentId,
                                        config.deviceId,
                                        config.tabletRole) { uploadState = it }
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

    /**
     * The PHYSICAL display, not the app's window.
     *
     * resources.displayMetrics reports the window, which shrinks with insets and
     * window state - the same tablet registered as 2560x1536 once and 1600x1200
     * the next time. Screen geometry is study-relevant, because reach distance is
     * part of what is being measured, and a number that drifts is worse than none.
     */
    private fun screenPx(): Pair<Int, Int> {
        val b = windowManager.maximumWindowMetrics.bounds
        return b.width() to b.height()
    }

    private fun deviceLine(): String {
        val (w, h) = screenPx()
        return "${android.os.Build.MODEL} · ${w}x$h · " +
               "${resources.displayMetrics.densityDpi} dpi · " +
               "Android ${android.os.Build.VERSION.RELEASE}"
    }

    /** Hold a downloaded play until its scheduled instant. */
    private fun arm(play: Play, startAt: Long) {
        armedPlay = play
        armedStartAt = startAt
        armedRemainingMs = startAt - server.serverNowMs()
        scenesTotal = play.trials.size
        uploadState = ""
        screen = Screen.ARMED
    }

    /** The instant arrived: the recorder is already running, so only run the play. */
    private fun beginArmed(play: Play) {
        if (!recorder.isRecording) startRecording(play)
        armedPlay = null
        // The scheduled instant, expressed on THIS device's clock. Both tablets
        // do the same conversion with their own measured offset, so both end up
        // with the same zero without ever comparing notes.
        runner.start(play, 0, zeroDeviceMs = armedStartAt - server.clockOffsetMs)
        screen = Screen.RUNNING
    }

    private fun cancelArmed() {
        armedPlay = null
        armedStartAt = 0L
        // Whatever pre-roll was captured is not a session; drop it rather than
        // leaving a stub folder that looks like an aborted run.
        if (recorder.isRecording) { beacon.stop(); motion.stop(); recorder.stop() }
        recorder.sessionName = Recorder.defaultName()
        screen = Screen.LIST
    }

    /**
     * Sensors, beacon and session files - everything except walking the play.
     *
     * Separate from begin() so an armed tablet can be recording, and its beacon
     * discoverable, before the play starts.
     */
    private fun startRecording(play: Play, joinedLateMs: Int = 0) {
        recorder.start()
        motion.start(recorder)
        // Only the tablet designated as the beacon advertises. Both advertising
        // under one name would put two devices behind a single label in the
        // watch's log, with no way to separate them afterwards.
        if (config.advertise) beacon.start(config.advertiseName)
        val (sw, sh) = screenPx()
        recorder.writeSessionFiles(play, SessionMeta(
            experimentId = config.experimentId, experimentName = config.experimentName,
            advertiseName = config.advertiseName, participant = config.participant,
            studyName = config.studyName, watchWrist = config.watchWrist,
            interactingHand = config.interactingHand, posture = config.posture,
            tabletOrientation = config.tabletOrientation, tabletRole = config.tabletRole,
            advertised = config.advertise,
            serverClockOffsetMs = server.clockOffsetMs,
            serverClockMeasured = server.clockKnown, joinedLateMs = joinedLateMs,
            playJson = "{}", screenWidthPx = sw, screenHeightPx = sh,
            densityDpi = resources.displayMetrics.densityDpi,
            density = resources.displayMetrics.density))
    }

    private fun begin(play: Play, joinedLateMs: Int) {
        scenesTotal = play.trials.size
        uploadState = ""
        startRecording(play, joinedLateMs)
        // Joining after the instant: the zero is still the schedule, just behind
        // us. Without a schedule at all it is the button press.
        runner.start(play, joinedLateMs,
                     zeroDeviceMs = System.currentTimeMillis() - joinedLateMs)
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
