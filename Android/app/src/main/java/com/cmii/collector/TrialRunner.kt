package com.cmii.collector

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Walks the play, scene by scene, on the clock.
 *
 * A port of the iPad's TrialRunner: the same phases, the same outcomes, the same
 * CSV row. Two tablets running two halves of one play must agree about what
 * happened in every slot, and the only way to be sure of that is for both to
 * decide it the same way.
 */
class TrialRunner {

    enum class Phase { IDLE, READY, CUED, SETTLING, GAP, DONE }

    var phase by mutableStateOf(Phase.IDLE); private set
    var index by mutableIntStateOf(0); private set
    var nDone by mutableIntStateOf(0); private set
    var skipped by mutableIntStateOf(0); private set
    var current by mutableStateOf<Trial?>(null); private set

    /**
     * Read by the board instead of `current`, so the grid does not collapse to
     * the default during the gap between scenes - the screen would visibly
     * reflow between every trial.
     */
    var displayTrial by mutableStateOf<Trial?>(null); private set

    /**
     * Milliseconds left in the scene now running, for the countdown on screen.
     *
     * This is time left in the SLOT, not in the cue window: the scene is over
     * when its slot is, whether or not the gesture was done in the first second.
     */
    var remainingMs by mutableLongStateOf(0L); private set

    var play: Play? = null; private set
    val total: Int get() = play?.trials?.size ?: 0
    val isRunning: Boolean get() = phase != Phase.IDLE && phase != Phase.DONE

    var onRow: ((String) -> Unit)? = null
    var onDeckRow: ((String) -> Unit)? = null
    var onFinished: (() -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0
    private var cueOnMs = 0L
    private var firstDownMs: Long? = null
    private var lastUpMs: Long? = null
    private var collected = mutableListOf<GestureRecord>()
    private var droppedOn: Int? = null

    /**
     * The play's own zero, on THIS device's clock.
     *
     * Every scene boundary is measured from here rather than from whenever the
     * previous scene happened to end. Two tablets derive it from the same
     * scheduled instant, corrected by each one's own measured server offset, so
     * they agree about when scene 7 begins without ever talking to each other.
     *
     * Kept in device time, not server time, because every timestamp written to
     * the CSVs is device time - a file with two clocks in it cannot be aligned
     * against the sensor stream.
     */
    private var zeroMs = 0L

    /**
     * A second cancellation token, for the slot boundary alone.
     *
     * `generation` is bumped by every phase change, which cancels everything
     * outstanding - correct for the phase timers, fatal for the one callback
     * that has to survive them. Without this the end-of-slot callback was
     * cancelled by the first cue and no scene ever advanced.
     */
    private var slotGen = 0

    /**
     * `joinedLateMs` lets a tablet enter a timeline that has already begun.
     *
     * The scheduled start of the experiment is the session's zero, not the moment
     * someone pressed the button: two tablets are pressed seconds apart by one
     * pair of hands, and with fixed slots that gap would persist all session.
     * Scenes already over are recorded as "not_run" rather than omitted, so the
     * file still accounts for every scene in the play.
     */
    fun start(p: Play, joinedLateMs: Int = 0, zeroDeviceMs: Long? = null) {
        play = p
        index = 0; nDone = 0; skipped = 0
        collected.clear()
        // Absent a schedule (a one-tablet play started by hand) the button press
        // is the zero, and joinedLateMs is 0.
        zeroMs = zeroDeviceMs ?: (System.currentTimeMillis() - joinedLateMs)
        slotGen++
        if (joinedLateMs > 0) {
            var cursor = 0
            for ((i, t) in p.trials.withIndex()) {
                val begins = t.startMs ?: cursor
                cursor = begins + t.slot(p)
                if (cursor > joinedLateMs) { index = i; break }
                index = i + 1
                skipped = i + 1
                onRow?.invoke(notRunRow(t))
            }
        }
        if (index >= p.trials.size) { phase = Phase.DONE; onFinished?.invoke(); return }
        beginReady()
        tick()
    }

    /** Where scene `i` begins and ends, on this device's clock. */
    private fun slotStart(i: Int): Long {
        val p = play ?: return zeroMs
        var cursor = 0
        for ((j, t) in p.trials.withIndex()) {
            val begins = t.startMs ?: cursor
            if (j == i) return zeroMs + begins
            cursor = begins + t.slot(p)
        }
        return zeroMs + cursor
    }

    private fun slotEnd(i: Int): Long {
        val p = play ?: return zeroMs
        val t = p.trials.getOrNull(i) ?: return slotStart(i)
        return slotStart(i) + t.slot(p)
    }

    /**
     * Drives the countdown, ten times a second.
     *
     * Independent of the phase timers on purpose: if a scheduled callback is
     * ever late, the number on screen still tells the truth about the slot.
     */
    private fun tick() {
        handler.postDelayed(object : Runnable {
            override fun run() {
                if (!isRunning) { remainingMs = 0; return }
                remainingMs = maxOf(0L, slotEnd(index) - System.currentTimeMillis())
                handler.postDelayed(this, 100)
            }
        }, 0)
    }

    fun abort() {
        generation++
        slotGen++
        handler.removeCallbacksAndMessages(null)
        phase = Phase.IDLE
        current = null
        displayTrial = null
    }

    // MARK: - Input

    fun touchDown(wallMs: Long) {
        if (phase != Phase.CUED) return
        if (firstDownMs == null) firstDownMs = wallMs
    }

    fun gesture(rec: GestureRecord) {
        if (phase != Phase.CUED && phase != Phase.SETTLING) return
        collected.add(rec)
        // wallMs is when the stroke STARTED; the end is start + duration. Using
        // wallMs alone left every trial with a zero-width window, useless for
        // slicing the watch stream.
        lastUpMs = rec.wallMs + rec.durMs.toLong()
        val p = play ?: return
        // A freeform scene runs its whole slot: the participant may be away from
        // the tablet, or using a web page, and a stray touch must not cut it short.
        if (phase != Phase.CUED || current?.isFreeform == true) return
        generation++
        phase = Phase.SETTLING
        at(minOf(System.currentTimeMillis() + p.settleMs, slotEnd(index))) {
            finish("completed")
        }
    }

    /**
     * App-level ground truth: the classifier can say "scroll" for a drag, but
     * only the board knows whether the card reached the block the scene asked
     * for. `to` is null when the card was thrown without landing anywhere.
     */
    fun cardDropped(from: Int, to: Int?, animal: String) {
        droppedOn = to
        deckRow(from, if (to == null) "dropMissed" else "dropped", animal, to)
    }

    /**
     * One row per thing the board did. This is the strongest evidence the
     * intended interaction happened - stronger than the classifier, which only
     * ever infers from the stroke.
     */
    fun deckRow(block: Int, event: String, animal: String, toBlock: Int? = null) {
        onDeckRow?.invoke(
            "${System.currentTimeMillis()},$index,$block,$event,$animal,${toBlock ?: ""}")
    }

    // MARK: - Phases

    private fun beginReady() {
        val p = play ?: return
        if (index >= p.trials.size) { finishStudy(); return }
        collected.clear(); firstDownMs = null; lastUpMs = null; droppedOn = null
        current = p.trials[index]
        displayTrial = current
        phase = Phase.READY
        generation++
        // Anchored to the slot, not to "now": a scene that begins a little late
        // must still end on time, or the lateness accumulates down the play and
        // the two tablets drift apart scene by scene.
        at(slotStart(index) + p.readyMs) { showCue() }
        atSlot(slotEnd(index)) { closeSlot() }
    }

    private fun showCue() {
        val p = play ?: return
        cueOnMs = System.currentTimeMillis()
        phase = Phase.CUED
        generation++
        val window = current?.durationMs ?: p.cueTimeoutMs
        // "waiting" says this tablet was not the one playing; "elapsed" says it
        // was and the window simply ran out; "timeout" says a cue went unanswered.
        val ending = when {
            current?.isWaiting == true -> "waiting"
            current?.isFreeform == true -> "elapsed"
            else -> "timeout"
        }
        // The cue window is the shorter of what the scene asks for and what is
        // left of the slot; the slot is what actually ends the scene.
        at(minOf(System.currentTimeMillis() + window, slotEnd(index))) { finish(ending) }
    }

    private fun finish(outcome: String) {
        val p = play ?: return
        val t = current ?: return
        generation++

        val observed = collected.maxByOrNull { it.pathLen }?.type ?: ""
        val match = matchOf(t, observed, outcome)
        onRow?.invoke(row(t, outcome, observed, match))
        nDone++

        // The row is written the moment the scene resolves, so the timing in the
        // file is the real timing - but the board waits out the rest of the slot
        // before moving on. Advancing early is what let two tablets wander
        // seconds apart, and it is also what made the scene number jump before
        // the countdown reached zero.
        phase = Phase.GAP
    }

    /** The slot is over: this is the only thing that advances the scene. */
    private fun closeSlot() {
        val p = play ?: return
        // A scene whose cue window is still open when the slot ends (a slot
        // shorter than the window, or a callback that did not fire) is resolved
        // here rather than being left unrecorded.
        if (phase == Phase.READY || phase == Phase.CUED || phase == Phase.SETTLING) {
            val ending = when {
                current?.isWaiting == true -> "waiting"
                current?.isFreeform == true -> "elapsed"
                else -> "timeout"
            }
            finish(ending)
        }
        generation++
        slotGen++
        index++
        if (index >= p.trials.size) finishStudy() else beginReady()
    }

    private fun finishStudy() {
        generation++
        phase = Phase.DONE
        current = null
        onFinished?.invoke()
    }

    private fun after(ms: Int, block: () -> Unit) {
        val g = generation
        handler.postDelayed({ if (g == generation) block() }, ms.toLong())
    }

    /** Run at an absolute instant on this device's clock, or at once if past. */
    private fun at(whenMs: Long, block: () -> Unit) {
        val g = generation
        handler.postDelayed({ if (g == generation) block() },
                            maxOf(0L, whenMs - System.currentTimeMillis()))
    }

    /** As `at`, but survives phase changes within the scene. */
    private fun atSlot(whenMs: Long, block: () -> Unit) {
        val g = slotGen
        handler.postDelayed({ if (g == slotGen) block() },
                            maxOf(0L, whenMs - System.currentTimeMillis()))
    }

    // MARK: - Scoring

    /**
     * Three states, not two: "1" matched, "0" did not, empty means unscored.
     *
     * A scene with no accepted labels in the book is perfectly usable for
     * collection; recording it as a failure would invent 20 misses a session.
     */
    private fun matchOf(t: Trial, observed: String, outcome: String): String {
        if (t.isFreeform) return ""
        if (t.acceptedLabels.isEmpty()) return ""
        if (outcome == "timeout") return "0"
        return if (observed in t.acceptedLabels) "1" else "0"
    }

    private fun row(t: Trial, outcome: String, observed: String, match: String): String =
        listOf(
            t.i, cueOnMs, t.row, t.col, t.type, t.dir ?: "", t.picture ?: "",
            firstDownMs ?: "", lastUpMs ?: "", outcome, observed, match,
            t.tag ?: "normal", t.durationMs ?: 0, t.rows ?: 0, t.cols ?: 0
        ).joinToString(",")

    /** A scene the tablet was not running for. Same shape as a played row, so
     *  the file has one row per scene either way. */
    private fun notRunRow(t: Trial): String =
        listOf(
            t.i, "", t.row, t.col, t.type, t.dir ?: "", t.picture ?: "",
            "", "", "not_run", "", "",
            t.tag ?: "normal", t.durationMs ?: 0, t.rows ?: 0, t.cols ?: 0
        ).joinToString(",")
}
