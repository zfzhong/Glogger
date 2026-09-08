package com.cmii.collector

import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
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
     * `joinedLateMs` lets a tablet enter a timeline that has already begun.
     *
     * The scheduled start of the experiment is the session's zero, not the moment
     * someone pressed the button: two tablets are pressed seconds apart by one
     * pair of hands, and with fixed slots that gap would persist all session.
     * Scenes already over are recorded as "not_run" rather than omitted, so the
     * file still accounts for every scene in the play.
     */
    fun start(p: Play, joinedLateMs: Int = 0) {
        play = p
        index = 0; nDone = 0; skipped = 0
        collected.clear()
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
    }

    fun abort() {
        generation++
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
        after(p.settleMs) { finish("completed") }
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
        after(p.readyMs) { showCue() }
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
        after(window) { finish(ending) }
    }

    private fun finish(outcome: String) {
        val p = play ?: return
        val t = current ?: return
        generation++

        val observed = collected.maxByOrNull { it.pathLen }?.type ?: ""
        val match = matchOf(t, observed, outcome)
        onRow?.invoke(row(t, outcome, observed, match))
        nDone++

        phase = Phase.GAP
        val gap = t.gapMs ?: p.gapMinMs
        after(gap) {
            index++
            if (index >= p.trials.size) finishStudy() else beginReady()
        }
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
