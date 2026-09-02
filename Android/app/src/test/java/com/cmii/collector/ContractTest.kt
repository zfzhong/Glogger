package com.cmii.collector

import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test
import java.net.URL

/**
 * The JSON is the contract between two platforms and one analysis pipeline, so
 * it is checked against the LIVE server rather than a fixture: a fixture only
 * proves the model matches what the model expected.
 */
class ContractTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val base = "https://withings.geosketch.art"

    private fun get(path: String) = URL(base + path).readText()

    @Test fun experimentsParse() {
        val list = json.decodeFromString<ExperimentList>(get("/cmii/experiments.json")).experiments
        assertTrue("no experiments returned", list.isNotEmpty())
        val runnable = list.filter { it.hasPlay }
        println("experiments=${list.size} runnable=${runnable.size}")
        runnable.forEach { println("  ${it.id} ${it.name} ${it.trialCount} scenes ${it.durationText} tablets=${it.tablets} start=${it.startAtMs}") }
    }

    @Test fun bothHalvesOfATwoTabletPlayLineUp() {
        val a = json.decodeFromString<Play>(get("/cmii/experiment/12/play.json?tablet=A"))
        val b = json.decodeFromString<Play>(get("/cmii/experiment/12/play.json?tablet=B"))
        assertEquals("halves differ in length", a.trials.size, b.trials.size)
        assertEquals(a.trials.map { it.startMs }, b.trials.map { it.startMs })
        // Exactly one side owns each slot.
        a.trials.zip(b.trials).forEach { (x, y) ->
            assertNotEquals("slot ${x.i} is waiting on both or live on both",
                            x.isWaiting, y.isWaiting)
        }
        println("A: " + a.trials.joinToString(" ") { if (it.isWaiting) "·" else it.type.take(4) })
        println("B: " + b.trials.joinToString(" ") { if (it.isWaiting) "·" else it.type.take(4) })
        println("waitingText=${a.waiting} label=${a.tabletLabel}")
    }

    @Test fun webMenuSceneParses() {
        val p = json.decodeFromString<Play>(get("/cmii/experiment/11/play.json"))
        val t = p.trials.first()
        assertTrue("not recognised as a web scene", t.isWeb)
        assertEquals(6, t.siteList.size)
        assertTrue(t.isFreeform)
        println("menu: " + t.siteList.joinToString(", ") { it.label })
    }

    @Test fun clockEndpointIsSane() {
        val body = get("/cmii/now.json")
        val serverMs = Regex("\"nowMs\"\\s*:\\s*(\\d+)").find(body)!!.groupValues[1].toLong()
        val delta = serverMs - System.currentTimeMillis()
        println("server minus this machine: ${delta} ms")
        assertTrue("clock offset implausible: $delta ms", Math.abs(delta) < 5 * 60_000)
    }
}
