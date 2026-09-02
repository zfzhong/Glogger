package com.cmii.collector

import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot

/**
 * On-device port of tools/gesture_parse.py, and a line-for-line match with the
 * iPad's GestureClassifier.swift.
 *
 * Three implementations of this logic now exist - Python for offline parsing,
 * Swift on the iPad, Kotlin here - and they must agree, because a classifier
 * that quietly disagrees between platforms turns "which tablet was it" into a
 * confound in the labels themselves. Any threshold change has to be made in all
 * three at once.
 *
 * UNITS. iOS reports touches in POINTS; Android reports them in PIXELS. On a 2x
 * device every distance and velocity therefore arrives doubled, and a 264 dp/s
 * drag reads as a 529 dp/s flick against a threshold calibrated in points - both
 * platforms writing "swipe" and "scroll" while meaning different things. The
 * thresholds are scaled by display density instead of scaling the data, so the
 * CSV keeps the digitiser's own resolution and analysis can convert with the
 * density recorded in session.json.
 *
 * Scaling makes the two platforms agree in principle; it does not make the
 * numbers right. They were calibrated on an iPad Pro 12.9" from four swipes and
 * four drags by one person, and the Pixel Tablet is a different size with a
 * different digitiser. Recalibrate from Android strokes before reading anything
 * into the swipe-versus-scroll split here.
 */
data class GestureThresholds(
    val longPressMs: Double = 500.0,
    val moveDist: Double = 10.0,      // pixels, once scaled
    /** Calibrated on iPad Pro 12.9": drags 228-365 pt/s, swipes 453-799, so 420
     *  is the midpoint of the gap. Provisional on Android until re-measured. */
    val flingVel: Double = 420.0,     // pixels/s, once scaled
    val pinchDelta: Double = 20.0,
    val rotateDeg: Double = 15.0
) {
    /**
     * The same thresholds expressed in this display's pixels.
     *
     * Duration and angle are unit-free and stay put; only the three distance and
     * velocity limits move. On a 2x tablet 420 pt/s becomes 840 px/s, which is
     * the same physical hand speed.
     */
    fun scaled(density: Float) = copy(
        moveDist = moveDist * density,
        flingVel = flingVel * density,
        pinchDelta = pinchDelta * density
    )
}

data class GestureRecord(
    val wallMs: Long,
    val kernelDown: Double,
    val kernelUp: Double,
    val type: String,
    val nFingers: Int,
    val x0: Int, val y0: Int, val x1: Int, val y1: Int,
    val durMs: Double,
    val disp: Double,
    val pathLen: Double,
    val meanVel: Double,
    val maxVel: Double
) {
    companion object {
        const val HEADER =
            "wall_ms,kernel_down,kernel_up,type,n_fingers,x0,y0,x1,y1," +
            "dur_ms,disp,path_len,mean_vel,max_vel"
    }

    val csvRow: String
        get() = "$wallMs,${r6(kernelDown)},${r6(kernelUp)},$type,$nFingers," +
                "$x0,$y0,$x1,$y1,${r1(durMs)},${r1(disp)},${r1(pathLen)}," +
                "${r1(meanVel)},${r1(maxVel)}"

    private fun r1(v: Double) = "%.1f".format(v)
    private fun r6(v: Double) = "%.6f".format(v)
}

private class Finger(val x0: Double, val y0: Double) {
    var x = x0
    var y = y0
    var path = 0.0
    val pts = ArrayList<Triple<Double, Double, Double>>()   // x, y, kernel-ts
}

/**
 * A "stroke" spans from the first finger down until the last finger lifts.
 * Mirrors iter_strokes/Stroke in gesture_parse.py.
 */
class StrokeAssembler(private val thr: GestureThresholds = GestureThresholds()) {

    private val active = HashSet<Int>()
    private val data = HashMap<Int, Finger>()
    private val order = ArrayList<Int>()      // first-seen order, so finger[0] is stable
    private var maxFingers = 0
    private var downKts = 0.0
    private var upKts = 0.0
    private var wall0 = 0L

    fun reset() {
        active.clear(); data.clear(); order.clear()
        maxFingers = 0; downKts = 0.0; upKts = 0.0; wall0 = 0
    }

    fun began(id: Int, x: Double, y: Double, kts: Double, wall: Long) {
        if (active.isEmpty()) {                 // a new stroke starts
            data.clear(); order.clear()
            maxFingers = 0; downKts = kts; upKts = kts; wall0 = wall
        }
        active.add(id)
        if (!data.containsKey(id)) order.add(id)
        data[id] = Finger(x, y).also { it.pts.add(Triple(x, y, kts)) }
        maxFingers = maxOf(maxFingers, data.size)
    }

    fun moved(id: Int, x: Double, y: Double, kts: Double) {
        val f = data[id] ?: return
        f.path += hypot(x - f.x, y - f.y)
        f.x = x; f.y = y
        f.pts.add(Triple(x, y, kts))
    }

    /** Returns the finished stroke when the LAST finger lifts, else null. */
    fun ended(id: Int, x: Double, y: Double, kts: Double): GestureRecord? {
        upKts = kts
        data[id]?.let { it.x = x; it.y = y }
        active.remove(id)
        if (active.isNotEmpty()) return null
        return finalizeStroke()
    }

    private fun finalizeStroke(): GestureRecord? {
        val fingers = order.mapNotNull { data[it] }
        val p = fingers.maxByOrNull { it.path } ?: return null
        val disp = hypot(p.x - p.x0, p.y - p.y0)
        val durMs = (upKts - downKts) * 1000.0
        val meanV = if (durMs > 0) p.path / (durMs / 1000.0) else 0.0
        var maxV = 0.0
        for (i in 1 until p.pts.size) {
            val dt = p.pts[i].third - p.pts[i - 1].third
            if (dt > 0) {
                val d = hypot(p.pts[i].first - p.pts[i - 1].first,
                              p.pts[i].second - p.pts[i - 1].second)
                maxV = maxOf(maxV, d / dt)
            }
        }
        val type = classify(maxFingers, disp, durMs, meanV, fingers)
        val rec = GestureRecord(
            wallMs = wall0, kernelDown = downKts, kernelUp = upKts, type = type,
            nFingers = maxFingers,
            x0 = Math.round(p.x0).toInt(), y0 = Math.round(p.y0).toInt(),
            x1 = Math.round(p.x).toInt(), y1 = Math.round(p.y).toInt(),
            durMs = durMs, disp = disp, pathLen = p.path, meanVel = meanV, maxVel = maxV)
        data.clear(); order.clear()
        return rec
    }

    private fun classify(nf: Int, disp: Double, durMs: Double,
                         meanV: Double, fingers: List<Finger>): String {
        if (nf >= 2 && fingers.size >= 2) {
            val a = fingers[0]; val b = fingers[1]
            val d0 = hypot(b.x0 - a.x0, b.y0 - a.y0)
            val d1 = hypot(b.x - a.x, b.y - a.y)
            val ang0 = atan2(b.y0 - a.y0, b.x0 - a.x0)
            val ang1 = atan2(b.y - a.y, b.x - a.x)
            val dAng = abs((ang1 - ang0) * 180.0 / Math.PI)
            if (abs(d1 - d0) > thr.pinchDelta) return "pinch"
            return if (dAng > thr.rotateDeg) "rotate" else "multi_tap"
        }
        if (disp > thr.moveDist) {
            return if (meanV > thr.flingVel) "swipe" else "scroll"
        }
        return if (durMs > thr.longPressMs) "long_press" else "tap"
    }
}
