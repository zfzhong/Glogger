package com.cmii.collector

import android.content.Context
import android.os.Build
import org.json.JSONObject

/**
 * An immutable snapshot of the settings at the moment a run starts, plus the
 * exact play the tablet was handed.
 *
 * Snapshotting means a mid-run settings change cannot alter what gets written
 * into this session's metadata, and the play is stored verbatim rather than
 * re-serialised: what the tablet actually ran is what belongs in the folder.
 */
data class SessionMeta(
    val experimentId: Int = 0,
    val experimentName: String = "",
    val advertiseName: String = "",
    val participant: String = "",
    val studyName: String = "",
    val watchWrist: String = "",
    val interactingHand: String = "",
    val posture: String = "",
    val tabletOrientation: String = "",
    val tabletRole: String = "A",
    val serverClockOffsetMs: Long = 0,
    val serverClockMeasured: Boolean = false,
    val joinedLateMs: Int = 0,
    /** The payload as the server sent it, byte for byte. */
    val playJson: String = "{}",
    val screenWidthPx: Int = 0,
    val screenHeightPx: Int = 0,
    val densityDpi: Int = 0
) {
    fun toJson(sessionName: String, play: Play): String {
        val o = JSONObject()
        o.put("session", sessionName)
        o.put("platform", "android")
        // Android fragmentation is real: touch geometry and reach distance vary
        // by device, so the device says what it is rather than being assumed.
        o.put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
        o.put("os", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        o.put("screen_px", "${screenWidthPx}x${screenHeightPx}")
        o.put("density_dpi", densityDpi)
        o.put("app", "GestureLogger")
        o.put("preset", "server:" + play.name)
        o.put("participant", participant)
        o.put("study", studyName)
        o.put("watch_wrist", watchWrist)
        o.put("interacting_hand", interactingHand)
        o.put("posture", posture)
        o.put("tablet_orientation", tabletOrientation)
        o.put("tablet_role", tabletRole)
        o.put("advertise_name", advertiseName)
        // Analysis needs this to put tablet rows and watch rows on one timeline,
        // and it moves in steps of seconds, so it is per session not per install.
        o.put("server_clock_offset_ms", serverClockOffsetMs)
        o.put("server_clock_measured", serverClockMeasured)
        o.put("joined_late_ms", joinedLateMs)
        if (experimentId > 0) {
            o.put("experiment_id", experimentId)
            o.put("experiment_name", experimentName)
        }
        return o.toString(2)
    }
}

/** Operator settings that persist across launches. */
class Config(context: Context) {
    private val p = context.getSharedPreferences("cmii", Context.MODE_PRIVATE)

    var serverBase: String
        get() = p.getString("serverBase", "https://withings.geosketch.art")!!
        set(v) = p.edit().putString("serverBase", v).apply()

    var uploadToken: String
        get() = p.getString("uploadToken", "")!!
        set(v) = p.edit().putString("uploadToken", v).apply()

    /** The watch matches on this EXACT string; Slogger's filter is not a prefix. */
    var advertiseName: String
        get() = p.getString("advertiseName", "CMII-Pad")!!
        set(v) = p.edit().putString("advertiseName", v).apply()

    /** Which tablet this is in a two-tablet play. */
    var tabletRole: String
        get() = p.getString("tabletRole", "A")!!
        set(v) = p.edit().putString("tabletRole", v).apply()

    var studyName: String
        get() = p.getString("studyName", "elicitation")!!
        set(v) = p.edit().putString("studyName", v).apply()

    var experimentId: Int
        get() = p.getInt("experimentId", 0)
        set(v) = p.edit().putInt("experimentId", v).apply()

    var experimentName: String
        get() = p.getString("experimentName", "")!!
        set(v) = p.edit().putString("experimentName", v).apply()

    // Adopted from the experiment when a run starts: the sitting is described
    // once on the server so two tablets cannot record it differently.
    var participant = ""
    var watchWrist = ""
    var interactingHand = ""
    var posture = ""
    var tabletOrientation = ""

    fun adopt(e: ExperimentInfo) {
        participant = e.participant
        watchWrist = e.watchWrist
        interactingHand = e.interactingHand
        posture = e.posture
        tabletOrientation = e.tabletOrientation
    }
}
