//
//  GestureClassifier.swift
//  On-device port of tools/gesture_parse.py (Stroke + classify), so gestures.csv
//  matches the offline pipeline column-for-column:
//    wall_ms,kernel_down,kernel_up,type,n_fingers,x0,y0,x1,y1,dur_ms,disp,path_len,mean_vel,max_vel
//
//  A "stroke" spans from the first finger down until the last finger lifts.
//  Thresholds are in POINTS/points-per-second here (getevent used raw device
//  units); calibrate per device — see README.
//
import Foundation
import CoreGraphics

/// Bumped whenever a threshold or a classification rule changes.
///
/// It goes into session.json so a `type` column can be interpreted later.
/// Without it, two sessions recorded a month apart carry the same word "swipe"
/// against different rules and nothing in the data says so — and the rules have
/// already changed twice this month.
///
///  1  original: longPress 500, moveDist 10, flingVel 420; hold shown at the
///     platform's own long-press timeout (iOS 0.35s, Android system setting).
///  2  hold pinned to 500ms on both platforms.
let gestureSpecVersion = 2

struct GestureThresholds {
    var longPressMs: Double = 500
    var moveDist: Double = 10        // points; getevent used 40 raw units
    // Calibrated on iPad Pro 12.9" from session 0824_1043 (4 cued swipes, 4 cued
    // drags by one person). Measured mean_vel: drags 228-365 pt/s, swipes 453-799.
    // The old 600 sat INSIDE the swipe class and misread the two slower swipes as
    // scroll. 420 is the midpoint of the gap, with ~60-90 pt/s margin either side.
    // Thin evidence (n=4 per class, one participant) - revisit with more people.
    // Note max_vel separates even better here (drags 826-1400, swipes 2471-3892);
    // worth evaluating as a rule change, but that must be done on BOTH platforms
    // together since gesture_parse.py mirrors this logic.
    var flingVel: Double = 420       // points/s
    var pinchDelta: Double = 20      // points
    var rotateDeg: Double = 15
    static let `default` = GestureThresholds()

    /// For session.json, so the label can be reinterpreted offline.
    var asDictionary: [String: Any] {
        ["spec_version": gestureSpecVersion,
         "units": "points",
         "density": 1.0,
         "long_press_ms": longPressMs,
         "move_dist": moveDist,
         "fling_vel": flingVel,
         "pinch_delta": pinchDelta,
         "rotate_deg": rotateDeg]
    }
}

struct GestureRecord {
    var wallMs: Int
    var kernelDown: Double
    var kernelUp: Double
    var type: String
    var nFingers: Int
    var x0: Int, y0: Int, x1: Int, y1: Int
    var durMs: Double
    var disp: Double
    var pathLen: Double
    var meanVel: Double
    var maxVel: Double

    static let header = "wall_ms,kernel_down,kernel_up,type,n_fingers,x0,y0,x1,y1,dur_ms,disp,path_len,mean_vel,max_vel"

    var csvRow: String {
        "\(wallMs),\(r6(kernelDown)),\(r6(kernelUp)),\(type),\(nFingers),"
        + "\(x0),\(y0),\(x1),\(y1),\(r1(durMs)),\(r1(disp)),\(r1(pathLen)),\(r1(meanVel)),\(r1(maxVel))"
    }
    private func r1(_ v: Double) -> String { String(format: "%.1f", v) }
    private func r6(_ v: Double) -> String { String(format: "%.6f", v) }
}

private struct Finger {
    var x0: Double, y0: Double
    var x: Double, y: Double
    var path: Double = 0
    var pts: [(Double, Double, Double)] = []   // x, y, kernel-ts
}

/// Feeds on (id, phase, x, y, kernelTs, wallMs); emits a GestureRecord when the
/// last finger of a stroke lifts. Mirrors iter_strokes/Stroke in gesture_parse.py.
final class StrokeAssembler {
    var thr: GestureThresholds
    var onGesture: ((GestureRecord) -> Void)?

    private var active = Set<ObjectIdentifier>()
    private var data: [ObjectIdentifier: Finger] = [:]
    private var order: [ObjectIdentifier] = []      // first-seen order (stable finger[0], [1])
    private var maxFingers = 0
    private var downKts = 0.0
    private var upKts = 0.0
    private var wall0 = 0

    init(thr: GestureThresholds = .default) { self.thr = thr }

    func began(_ id: ObjectIdentifier, _ x: Double, _ y: Double, _ kts: Double, _ wall: Int) {
        if active.isEmpty {                          // new stroke starts
            data.removeAll(); order.removeAll()
            maxFingers = 0; downKts = kts; upKts = kts; wall0 = wall
        }
        active.insert(id)
        if data[id] == nil { order.append(id) }
        data[id] = Finger(x0: x, y0: y, x: x, y: y, pts: [(x, y, kts)])
        maxFingers = max(maxFingers, data.count)
    }

    func moved(_ id: ObjectIdentifier, _ x: Double, _ y: Double, _ kts: Double) {
        guard var f = data[id] else { return }
        f.path += hypot(x - f.x, y - f.y)
        f.x = x; f.y = y; f.pts.append((x, y, kts))
        data[id] = f
    }

    func ended(_ id: ObjectIdentifier, _ x: Double, _ y: Double, _ kts: Double) {
        upKts = kts
        if var f = data[id] { f.x = x; f.y = y; data[id] = f }
        active.remove(id)
        if active.isEmpty { finalizeStroke() }
    }

    private func finalizeStroke() {
        let fingers = order.compactMap { data[$0] }
        guard let p = fingers.max(by: { $0.path < $1.path }) else { return }
        let disp = hypot(p.x - p.x0, p.y - p.y0)
        let durMs = (upKts - downKts) * 1000.0
        let meanV = durMs > 0 ? p.path / (durMs / 1000.0) : 0
        var maxV = 0.0
        for i in 1..<max(p.pts.count, 1) where p.pts.count > 1 {
            let dt = p.pts[i].2 - p.pts[i-1].2
            if dt > 0 {
                let d = hypot(p.pts[i].0 - p.pts[i-1].0, p.pts[i].1 - p.pts[i-1].1)
                maxV = max(maxV, d / dt)
            }
        }
        let type = classify(nFingers: maxFingers, disp: disp, durMs: durMs,
                            meanV: meanV, fingers: fingers)
        onGesture?(GestureRecord(
            wallMs: wall0, kernelDown: downKts, kernelUp: upKts, type: type,
            nFingers: maxFingers,
            x0: Int(p.x0.rounded()), y0: Int(p.y0.rounded()),
            x1: Int(p.x.rounded()),  y1: Int(p.y.rounded()),
            durMs: durMs, disp: disp, pathLen: p.path, meanVel: meanV, maxVel: maxV))
        data.removeAll(); order.removeAll()
    }

    private func classify(nFingers nf: Int, disp: Double, durMs: Double,
                          meanV: Double, fingers: [Finger]) -> String {
        if nf >= 2, fingers.count >= 2 {
            let a = fingers[0], b = fingers[1]
            let d0 = hypot(b.x0 - a.x0, b.y0 - a.y0)
            let d1 = hypot(b.x - a.x, b.y - a.y)
            let ang0 = atan2(b.y0 - a.y0, b.x0 - a.x0)
            let ang1 = atan2(b.y - a.y, b.x - a.x)
            let dAng = abs((ang1 - ang0) * 180.0 / .pi)
            if abs(d1 - d0) > thr.pinchDelta { return "pinch" }
            return dAng > thr.rotateDeg ? "rotate" : "multi_tap"
        }
        if disp > thr.moveDist {
            return meanV > thr.flingVel ? "swipe" : "scroll"
        }
        return durMs > thr.longPressMs ? "long_press" : "tap"
    }
}
