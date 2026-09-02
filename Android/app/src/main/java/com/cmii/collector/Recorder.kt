package com.cmii.collector

import android.content.Context
import android.view.MotionEvent
import java.io.File
import java.io.Writer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Session state and CSV writers.
 *
 * The schemas are byte-identical to the iPad's, because one analysis pipeline
 * reads both platforms - a column that means something slightly different on
 * Android would be worse than a missing one, since nothing would complain.
 *
 *   <name>_taps.csv         tablet_wall_ms,kernel_ts,x,y
 *   <name>_touches_raw.csv  wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase,kbd
 *   <name>_gestures.csv     14 columns from the classifier
 *   <name>_deck.csv         wall_ms,trial_idx,block,event,animal,to_block
 *   <name>_web.csv          wall_ms,trial_idx,event,detail
 *   <name>_ble.csv          wall_ms,name,uuid,rssi
 *   <name>_trials.csv       16 columns, one row per scene
 *   <name>_imu_*.csv        wall_ms,kernel_ts,x,y,z
 *
 * `kernel_ts` is seconds since boot on both platforms - iOS takes it from
 * UITouch.timestamp, Android from MotionEvent.eventTime, which is uptimeMillis.
 * Same clock meaning, same units, so a stroke can be aligned the same way
 * whichever tablet recorded it.
 */
class Recorder(private val context: Context) {

    var sessionName: String = defaultName()
    var sessionDir: File? = null; private set
    var isRecording: Boolean = false; private set

    var nTaps = 0; private set
    var nGestures = 0; private set
    var nBle = 0; private set
    var nImu = 0; private set
    var status: String = "Idle"; private set

    /** Touches during a scene are attributed to it. -1 outside a run. */
    var trialIndex: Int = -1

    /**
     * True while a keyboard is on screen. Touch COORDINATES are withheld for the
     * duration: over a keyboard they are the text being typed, and this corpus
     * includes recordings of children. Timing, duration and pressure survive,
     * which is what the wrist-side detector is trained against.
     */
    var keyboardUp: Boolean = false

    var onTouchDown: ((Long) -> Unit)? = null
    var onGesture: ((GestureRecord) -> Unit)? = null

    private var taps: Writer? = null
    private var raw: Writer? = null
    private var gestures: Writer? = null
    private var deck: Writer? = null
    private var web: Writer? = null
    private var ble: Writer? = null
    private var trials: Writer? = null
    private var accel: Writer? = null
    private var gyro: Writer? = null
    private var mag: Writer? = null

    /** Pixels, not points: the classifier's limits are scaled to this display so
     *  the same physical gesture gets the same label on both platforms. */
    private val density = context.resources.displayMetrics.density
    private val assembler = StrokeAssembler(GestureThresholds().scaled(density))
    private val slots = HashMap<Int, Int>()   // pointer id -> stable small id
    private var nextSlot = 0

    companion object {
        fun defaultName(): String =
            SimpleDateFormat("MMdd_HHmm", Locale.US).format(Date())

        /** `name`, or `name_2`... - the first that is not already holding a
         *  recorded session. A second run in the same launch minute used to
         *  reuse the folder and truncate the first run's files. */
        fun freeName(name: String, root: File): String {
            fun taken(n: String) = File(root, "sessions/$n").listFiles()?.isNotEmpty() == true
            if (!taken(name)) return name
            for (i in 2..99) if (!taken("${name}_$i")) return "${name}_$i"
            return "${name}_${System.currentTimeMillis() / 1000}"
        }
    }

    private fun open(dir: File, suffix: String, header: String): Writer {
        val f = File(dir, sessionName + suffix)
        val w = f.bufferedWriter()
        w.write(header); w.write("\n")
        return w
    }

    fun start() {
        if (isRecording) return
        // Internal storage: /sdcard/Android/data is unreadable to adb on Android
        // 11+, and these are behavioural recordings of named participants - they
        // have no business being world-readable either.
        val root = context.filesDir
        sessionName = freeName(sessionName, root)
        val dir = File(root, "sessions/$sessionName").apply { mkdirs() }
        sessionDir = dir

        taps = open(dir, "_taps.csv", "tablet_wall_ms,kernel_ts,x,y")
        raw = open(dir, "_touches_raw.csv",
            "wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase,kbd")
        gestures = open(dir, "_gestures.csv", GestureRecord.HEADER)
        deck = open(dir, "_deck.csv", "wall_ms,trial_idx,block,event,animal,to_block")
        web = open(dir, "_web.csv", "wall_ms,trial_idx,event,detail")
        ble = open(dir, "_ble.csv", "wall_ms,name,uuid,rssi")
        trials = open(dir, "_trials.csv", TRIALS_HEADER)
        val imu = "wall_ms,kernel_ts,x,y,z"
        accel = open(dir, "_imu_accel.csv", imu)
        gyro = open(dir, "_imu_gyro.csv", imu)
        mag = open(dir, "_imu_mag.csv", imu)

        nTaps = 0; nGestures = 0; nBle = 0; nImu = 0
        slots.clear(); nextSlot = 0
        assembler.reset()
        isRecording = true
        status = "Recording → $sessionName"
    }

    fun stop() {
        if (!isRecording) return
        isRecording = false
        listOf(taps, raw, gestures, deck, web, ble, trials, accel, gyro, mag).forEach {
            try { it?.flush(); it?.close() } catch (_: Exception) { }
        }
        taps = null; raw = null; gestures = null; deck = null; web = null
        ble = null; trials = null; accel = null; gyro = null; mag = null
        status = "Saved $nTaps touches, $nGestures gestures, $nBle BLE, $nImu IMU → $sessionName"
    }

    private fun write(w: Writer?, line: String) {
        if (!isRecording) return
        try { w?.write(line); w?.write("\n") } catch (_: Exception) { }
    }

    // MARK: - Touch

    /**
     * Every pointer of every event, including the historical samples Android
     * batches between frames. Dropping those would quietly halve the sample rate
     * of a fast drag - exactly the strokes the wrist model most needs.
     */
    fun ingest(ev: MotionEvent) {
        if (!isRecording) return
        val wall = System.currentTimeMillis()

        fun row(pointer: Int, kernelMs: Long, x: Float, y: Float, phase: String) {
            val id = ev.getPointerId(pointer)
            val slot = slots.getOrPut(id) { nextSlot++ }
            val kts = "%.6f".format(kernelMs / 1000.0)
            val xy = if (keyboardUp) "," else "${x.toInt()},${y.toInt()}"
            write(raw, "$wall,$kts,$slot,$phase,$xy," +
                    "%.3f,%.3f,0,%s".format(ev.getPressure(pointer),
                                            ev.getTouchMajor(pointer),
                                            if (keyboardUp) "1" else "0"))
            when (phase) {
                "began" -> {
                    nTaps++
                    onTouchDown?.invoke(wall)
                    if (!keyboardUp) {
                        write(taps, "$wall,$kts,${x.toInt()},${y.toInt()}")
                        assembler.began(slot, x.toDouble(), y.toDouble(), kernelMs / 1000.0, wall)
                    }
                }
                "moved" -> if (!keyboardUp)
                    assembler.moved(slot, x.toDouble(), y.toDouble(), kernelMs / 1000.0)
                "ended", "cancelled" -> {
                    if (!keyboardUp) {
                        assembler.ended(slot, x.toDouble(), y.toDouble(), kernelMs / 1000.0)?.let {
                            nGestures++
                            write(gestures, it.csvRow)
                            onGesture?.invoke(it)
                        }
                    }
                    slots.remove(id)
                }
            }
        }

        val action = ev.actionMasked
        when (action) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                val p = ev.actionIndex
                row(p, ev.eventTime, ev.getX(p), ev.getY(p), "began")
            }
            MotionEvent.ACTION_MOVE -> {
                // Historical samples first, in order, then the current one.
                for (h in 0 until ev.historySize)
                    for (p in 0 until ev.pointerCount)
                        row(p, ev.getHistoricalEventTime(h),
                            ev.getHistoricalX(p, h), ev.getHistoricalY(p, h), "moved")
                for (p in 0 until ev.pointerCount)
                    row(p, ev.eventTime, ev.getX(p), ev.getY(p), "moved")
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val p = ev.actionIndex
                row(p, ev.eventTime, ev.getX(p), ev.getY(p), "ended")
            }
            MotionEvent.ACTION_CANCEL -> {
                for (p in 0 until ev.pointerCount)
                    row(p, ev.eventTime, ev.getX(p), ev.getY(p), "cancelled")
            }
        }
    }

    // MARK: - Other streams

    fun writeImu(kind: String, kernelNs: Long, x: Float, y: Float, z: Float) {
        if (!isRecording) return
        nImu++
        val line = "${System.currentTimeMillis()},%.6f,%.6f,%.6f,%.6f"
            .format(kernelNs / 1_000_000_000.0, x, y, z)
        write(when (kind) { "accel" -> accel; "gyro" -> gyro; else -> mag }, line)
    }

    fun writeBle(name: String, address: String, rssi: Int) {
        if (!isRecording) return
        nBle++
        write(ble, "${System.currentTimeMillis()},$name,$address,$rssi")
    }

    fun writeTrialRow(line: String) = write(trials, line)
    fun writeDeckRow(line: String) = write(deck, line)

    /** Commas and newlines in a URL or an error message would split the row. */
    fun writeWebRow(trial: Int, event: String, detail: String) {
        val safe = detail.replace("\"", "\"\"")
        write(web, "${System.currentTimeMillis()},$trial,$event,\"$safe\"")
    }

    fun writeSessionFiles(play: Play, meta: SessionMeta) {
        val dir = sessionDir ?: return
        try {
            File(dir, "${sessionName}_play.json").writeText(meta.playJson)
            File(dir, "${sessionName}_session.json").writeText(meta.toJson(sessionName, play))
        } catch (_: Exception) { }
    }

    fun csvFiles(): List<File> =
        sessionDir?.listFiles { f -> f.name.endsWith(".csv") || f.name.endsWith(".json") }
            ?.sortedBy { it.name } ?: emptyList()
}

const val TRIALS_HEADER =
    "trial_idx,cue_on_ms,block_row,block_col,cued_gesture,cued_direction,picture_id," +
    "first_down_ms,last_up_ms,outcome,classified_gesture,match,pace_tag,cue_duration_ms," +
    "grid_rows,grid_cols"
