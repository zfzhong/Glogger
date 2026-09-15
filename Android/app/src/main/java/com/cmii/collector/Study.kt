package com.cmii.collector

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The play, exactly as the server ships it.
 *
 * This mirrors the iOS Study.swift because the JSON is the contract between the
 * two platforms - the same play.json has to drive an iPad and this tablet, and
 * the CSVs they write have to be read by one analysis pipeline. Where the two
 * apps must agree, they agree here.
 *
 * Every field the server may omit is nullable with a default: an older payload,
 * or a scene type this build does not know, must not fail to parse. A tablet
 * that refuses to start because of an unexpected key is worse than one that
 * renders a scene plainly.
 */

@Serializable
data class WebSite(
    val label: String = "",
    val url: String = ""
) {
    /** Null for anything that is not plain https - the tile is dropped rather
     *  than offering the participant a page that will not load. */
    val link: String?
        get() = url.takeIf { it.startsWith("https://") }
}

@Serializable
data class Trial(
    val i: Int = 0,
    val type: String = "",
    val dir: String? = null,
    val device: Int = 0,
    val row: Int = 0,
    val col: Int = 0,
    val rows: Int? = null,
    val cols: Int? = null,
    val picture: String? = null,
    val durationMs: Int? = null,
    val slotMs: Int? = null,
    val startMs: Int? = null,
    val gapMs: Int? = null,
    val verb: String? = null,
    val directional: Boolean? = null,
    val affordance: String? = null,
    val dirWord: String? = null,
    val dirIcon: String? = null,
    val dirVerifiable: Boolean? = null,
    val acceptedLabels: List<String> = emptyList(),
    val tag: String? = null,
    val travels: Boolean? = null,
    val toRow: Int? = null,
    val toCol: Int? = null,
    val toPicture: String? = null,
    val prompt: String? = null,
    /** Away from the tablet entirely - reaching for the water bottle. */
    val offscreen: Boolean? = null,
    /** A slot this tablet does not own; the other one is playing. */
    val empty: Boolean? = null,
    /** A pinned page, or a menu of them. */
    val web: Boolean? = null,
    val url: String? = null,
    val sites: List<WebSite> = emptyList()
) {
    val isOffscreen: Boolean get() = offscreen == true
    val isWaiting: Boolean get() = empty == true
    val isWeb: Boolean get() = web == true && (webUrl != null || siteList.isNotEmpty())

    val webUrl: String? get() = url?.takeIf { it.startsWith("https://") }
    val siteList: List<WebSite> get() = sites.filter { it.link != null }

    /**
     * Neither a waiting slot, an off-screen prompt nor a web page cues a gesture
     * on the board, so all three run their slot out on the clock rather than
     * ending when someone happens to touch the screen.
     */
    val isFreeform: Boolean get() = isOffscreen || isWaiting || isWeb

    /**
     * Whether this scene should show the card before the gesture.
     *
     * A drag and a flick both act on a particular card and move it somewhere -
     * out of the deck, or off the board - so the participant has to see which
     * card that is. A tap does not: the card has to start face down or there is
     * nothing to flip, and the flip is the gesture being measured.
     */
    val revealsCard: Boolean get() = isTravelling || type == "swipe"

    val promptText: String get() = prompt.orEmpty()

    val displayVerb: String
        get() = (verb ?: type).replaceFirstChar { it.uppercase() }

    val directionWord: String get() = dirWord ?: dir.orEmpty().lowercase()

    val isTravelling: Boolean get() = travels == true && toRow != null && toCol != null

    fun grid(default: Play): Pair<Int, Int> =
        Pair(rows ?: default.rows, cols ?: default.cols)

    /** How long this scene occupies, falling back the way the server does. */
    fun slot(play: Play): Int =
        slotMs ?: (play.readyMs + (durationMs ?: play.cueTimeoutMs) + play.settleMs)
}

@Serializable
data class Play(
    val playVersion: Int = 3,
    val name: String = "",
    val seed: Long = 0,
    val rows: Int = 2,
    val cols: Int = 2,
    val readyMs: Int = 800,
    val cueTimeoutMs: Int = 6000,
    val gapMinMs: Int = 1200,
    val gapMaxMs: Int = 2500,
    val settleMs: Int = 450,
    val layouts: List<String>? = null,
    val blockPictures: List<String> = emptyList(),
    val trials: List<Trial> = emptyList(),
    val totalMs: Int = 0,
    val waitingText: String? = null,
    /** Present only on a half handed to one tablet. */
    val device: Int? = null,
    val tabletLabel: String? = null,
    val experimentId: Int? = null,
    val experimentName: String? = null,
    val scheduledStartMs: Long? = null,
    val playId: Int? = null
) {
    val count: Int get() = trials.size
    val waiting: String get() = waitingText?.takeIf { it.isNotBlank() } ?: "Please read the other Device"
}

@Serializable
data class ExperimentInfo(
    val id: Int,
    val name: String = "",
    val description: String = "",
    val sessions: Int = 0,
    val playId: Int? = null,
    val playName: String? = null,
    val trialCount: Int = 0,
    val totalMs: Int = 0,
    val tablets: Int = 1,
    val notes: String? = null,
    val startISO: String? = null,
    // The sitting, described once on the server so two tablets cannot disagree.
    val participant: String = "",
    val watchWrist: String = "",
    val interactingHand: String = "",
    val posture: String = "",
    val tabletOrientation: String = "",
    val missing: List<String> = emptyList(),
    // Which device plays which half. A tablet matches its own id against these
    // rather than being told its role by hand.
    val tabletA: String? = null,
    val tabletB: String? = null,
    val tabletALabel: String? = null,
    val tabletBLabel: String? = null,
    val advertiseA: String? = null,
    val advertiseB: String? = null,
    /** "B", "A" or "both" — which tablet the watch scans for in this experiment. */
    val beacon: String = "B",
    /**
     * A testing experiment: every tablet lists it, it needs no schedule and no
     * assignment, and its sessions are not participant data. Shown as such on
     * the list, because it is the one experiment that skips every check.
     */
    val free: Boolean = false
) {
    /**
     * Whether THIS tablet is a beacon here.
     *
     * A single-tablet run always advertises: there is no decoy to contrast
     * against, and a silent lone tablet leaves the watch with nothing.
     */
    fun advertisesFor(deviceId: String): Boolean {
        if (tablets <= 1) return true
        // Free and unassigned: nobody is the decoy, so whoever picked it up is
        // the beacon. Otherwise a test looks like a BLE fault.
        if (free && tabletA == null && tabletB == null) return true
        val mine = roleFor(deviceId) ?: return false
        return beacon == "both" || beacon == mine
    }

    val hasAssignment: Boolean get() = tabletA != null || tabletB != null

    /** This device's half, or null when it is not one of the assigned tablets. */
    fun roleFor(deviceId: String): String? = when (deviceId) {
        tabletA -> "A"
        tabletB -> "B"
        else -> null
    }

    /** The advertise name for this device's half, as the server holds it. */
    fun advertiseFor(deviceId: String): String? = when (deviceId) {
        tabletA -> advertiseA
        tabletB -> advertiseB
        else -> null
    }

    /**
     * What this tablet is for THIS experiment, or null if it cannot run it.
     *
     * Assigned: the server decides. Unassigned single-tablet: there is no decoy,
     * so the one tablet is the beacon. Unassigned two-tablet: refused - neither
     * tablet can know which half it is, and guessing would either silence the
     * beacon or duplicate it.
     */
    fun resolvedRole(deviceId: String): String? {
        // A free experiment is offered to every tablet, assigned or not. An
        // assignment is still honoured where one exists, so a free two-tablet
        // play can still be split deliberately.
        if (free) return roleFor(deviceId) ?: if (tablets <= 1) "B" else "A"
        // An experiment with no device assigned is not ready, whatever else is
        // set on it, so no tablet offers it.
        val mine = roleFor(deviceId) ?: return null
        // A and B only mean anything when there are two. With one tablet there is
        // no decoy to contrast against, so it is the beacon whichever slot it was
        // assigned to - otherwise a single-tablet run assigned to slot A would go
        // silent and the watch would record nothing at all.
        return if (tablets <= 1) "B" else mine
    }

    val assignedTo: String
        get() = listOfNotNull(
            tabletALabel?.let { "A: $it" }, tabletBLabel?.let { "B: $it" }
        ).joinToString(" · ")

    val hasPlay: Boolean get() = (playId ?: 0) > 0 && trialCount > 0

    /** Why Start is unavailable, in the operator's terms rather than the schema's. */
    val blockedReason: String
        get() = when {
            (playId ?: 0) == 0 -> "no play assigned"
            trialCount == 0 -> "its play has no scenes"
            else -> ""
        }

    val durationText: String
        get() {
            val s = totalMs / 1000
            return if (s >= 60) "${s / 60} min" + if (s % 60 == 0) "" else " ${s % 60} s"
            else "$s s"
        }

    /** Epoch millis of the scheduled start, or null. */
    val startAtMs: Long?
        get() = startISO?.takeIf { it.isNotBlank() }?.let { Iso.parse(it) }
}

@Serializable
data class ExperimentList(val experiments: List<ExperimentInfo> = emptyList())
