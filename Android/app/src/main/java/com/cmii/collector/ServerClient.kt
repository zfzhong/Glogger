package com.cmii.collector

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * Everything the tablet reads from the collection server.
 *
 * Wifi is a precondition for the bench - the whole configuration lives on the
 * server - so a play is always fetched fresh and a failed fetch is a hard stop.
 * Falling back to a copy on disk would let an operator run yesterday's play
 * after editing it on the web, with nothing on screen saying so.
 *
 * The experiment LIST is cached, because a momentary hiccup there only decides
 * whether the landing screen is blank; it can never cause a stale run.
 */
class ServerClient(private val cacheDir: java.io.File) {

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    /**
     * serverNow - deviceNow, in milliseconds.
     *
     * Two tablets enter the timeline measured from one absolute instant, and a
     * tablet's own clock can sit seconds off. Judging the schedule on the device
     * clock would put the pair out of step by exactly that error, silently.
     */
    @Volatile var clockOffsetMs: Long = 0; private set
    @Volatile var clockKnown: Boolean = false; private set

    fun deviceNowMs(): Long = System.currentTimeMillis()
    fun serverNowMs(): Long = deviceNowMs() + clockOffsetMs

    private fun root(base: String) = base.trim().trimEnd('/')

    /** Round-trip compensated: the server's reading is taken as the midpoint of
     *  the exchange, which is as good as this gets over HTTP. */
    suspend fun syncClock(base: String) = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url(root(base) + "/cmii/now.json")
                .header("Cache-Control", "no-cache").build()
            val t0 = System.currentTimeMillis()
            http.newCall(req).execute().use { resp ->
                val t1 = System.currentTimeMillis()
                val body = resp.body?.string().orEmpty()
                val serverMs = Regex("\"nowMs\"\\s*:\\s*(\\d+)")
                    .find(body)?.groupValues?.get(1)?.toLongOrNull()
                if (resp.isSuccessful && serverMs != null) {
                    clockOffsetMs = serverMs - (t0 + t1) / 2
                    clockKnown = true
                }
            }
        } catch (_: Exception) {
            // Keep the last known offset. A momentary failure should not move
            // every scheduled start by the size of the drift.
        }
    }

    /**
     * Announce this tablet, and learn what the server calls it.
     *
     * Cheap and idempotent, so it runs on every list refresh: a tablet that has
     * just been named on the web picks that up without anyone restarting it.
     */
    suspend fun register(
        base: String, deviceId: String, model: String, os: String, screen: String
    ): Pair<String, String>? = withContext(Dispatchers.IO) {
        try {
            val form = okhttp3.FormBody.Builder()
                .add("device_id", deviceId).add("platform", "android")
                .add("model", model).add("os_version", os).add("screen", screen)
                .build()
            val req = Request.Builder().url(root(base) + "/cmii/device/register/")
                .post(form).build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val body = resp.body?.string().orEmpty()
                fun field(k: String) =
                    Regex("\"$k\"\\s*:\\s*\"([^\"]*)\"").find(body)?.groupValues?.get(1).orEmpty()
                field("name") to field("advertiseName")
            }
        } catch (_: Exception) { null }
    }

    suspend fun loadExperiments(base: String): Pair<List<ExperimentInfo>, String> =
        withContext(Dispatchers.IO) {
            syncClock(base)
            try {
                val req = Request.Builder().url(root(base) + "/cmii/experiments.json").build()
                http.newCall(req).execute().use { resp ->
                    val body = resp.body?.string().orEmpty()
                    if (!resp.isSuccessful) return@withContext cachedList() to "server error ${resp.code}"
                    val list = json.decodeFromString<ExperimentList>(body).experiments
                    listCache.writeText(body)
                    list to "${list.size} experiment${if (list.size == 1) "" else "s"} · just now"
                }
            } catch (_: Exception) {
                val cached = cachedList()
                if (cached.isNotEmpty()) cached to "offline — showing the last list this tablet saw"
                else emptyList<ExperimentInfo>() to "could not reach the server"
            }
        }

    /**
     * This tablet's half of the play, always from the server.
     *
     * `tablet` selects the half: the server returns the same scene count and the
     * same slot boundaries either way, with the other tablet's scenes replaced by
     * empty ones. Ignored for a one-tablet play.
     */
    suspend fun fetchPlay(base: String, experimentId: Int, tablet: String): Pair<Play?, String> =
        withContext(Dispatchers.IO) {
            try {
                val url = root(base) + "/cmii/experiment/$experimentId/play.json?tablet=" +
                        tablet.ifBlank { "A" }
                val req = Request.Builder().url(url)
                    .header("Cache-Control", "no-cache").build()
                http.newCall(req).execute().use { resp ->
                    when {
                        resp.code == 404 -> null to "that experiment has no play assigned"
                        !resp.isSuccessful -> null to "server error ${resp.code}"
                        else -> {
                            val play = json.decodeFromString<Play>(resp.body?.string().orEmpty())
                            play to "fetched ${play.trials.size} scenes"
                        }
                    }
                }
            } catch (_: Exception) {
                null to "could not reach the server — check wifi and try again"
            }
        }

    private val listCache get() = java.io.File(cacheDir, "experiments.json")

    private fun cachedList(): List<ExperimentInfo> = try {
        if (listCache.exists())
            json.decodeFromString<ExperimentList>(listCache.readText()).experiments
        else emptyList()
    } catch (_: Exception) { emptyList() }
}

/** ISO-8601 with or without fractional seconds, as Django emits it. */
object Iso {
    fun parse(s: String): Long? {
        val patterns = listOf(
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'",
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        for (p in patterns) {
            try {
                val f = java.text.SimpleDateFormat(p, java.util.Locale.US)
                return f.parse(s)?.time
            } catch (_: Exception) { }
        }
        return null
    }
}
