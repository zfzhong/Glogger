//
//  Recorder.swift
//  Session state + CSV writers. Produces, per session folder in Documents:
//
//    <name>_taps.csv          tablet_wall_ms,kernel_ts,x,y            (one row per touch-down)
//    <name>_touches_raw.csv   wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase
//                             (full stream — the source-of-truth analog to getevent.log)
//    <name>_gestures.csv      14-col schema from GestureClassifier (matches the pipeline)
//    <name>_ble.csv           wall_ms,name,uuid,rssi
//
//  taps.csv and gestures.csv are byte-schema-compatible with the existing Python
//  analysis; the raw stream carries the iOS extras (force, radius, study phase).
//
import Foundation
import SwiftUI
import UIKit

final class Recorder: ObservableObject {
    @Published var isRecording = false
    @Published var sessionName = Recorder.defaultName()
    @Published var bleFilter = "watch"
    @Published var studyPhase = 0                 // 0 browse, 1 type, 2 tap-grid
    @Published var status = "Idle"
    @Published var nTaps = 0
    @Published var nGestures = 0
    @Published var nBle = 0
    @Published private(set) var sessionDir: URL?

    /// Hooks for the study engine (set by ContentView). Called on the main thread.
    var onTouchDown: ((Int) -> Void)?
    var onGestureRecord: ((GestureRecord) -> Void)?

    private var tapsFile: FileHandle?
    private var trialsFile: FileHandle?
    private var rawFile: FileHandle?
    private var gestFile: FileHandle?
    private var bleFile: FileHandle?

    private let scanner = BLEScanner()
    private let assembler = StrokeAssembler(thr: .default)
    private var touchSlot: [ObjectIdentifier: Int] = [:]   // stable small ids for the raw log
    private var nextSlot = 0

    static func defaultName() -> String {
        let f = DateFormatter(); f.dateFormat = "MMdd_HHmm"
        return f.string(from: Date())
    }

    // MARK: - Session lifecycle

    func start() {
        guard !isRecording else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions/\(sessionName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir

        tapsFile = openFile(dir, "_taps.csv",        header: "tablet_wall_ms,kernel_ts,x,y")
        rawFile  = openFile(dir, "_touches_raw.csv", header: "wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase")
        gestFile = openFile(dir, "_gestures.csv",    header: GestureRecord.header)
        bleFile  = openFile(dir, "_ble.csv",         header: "wall_ms,name,uuid,rssi")
        trialsFile = openFile(dir, "_trials.csv",    header: TrialRunner.csvHeader)

        nTaps = 0; nGestures = 0; nBle = 0
        touchSlot.removeAll(); nextSlot = 0

        assembler.onGesture = { [weak self] rec in
            guard let self else { return }
            self.append(self.gestFile, rec.csvRow)
            DispatchQueue.main.async {
                self.nGestures += 1
                self.onGestureRecord?(rec)
            }
        }
        scanner.nameFilter = bleFilter
        scanner.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        scanner.onSample = { [weak self] date, name, uuid, rssi in
            guard let self else { return }
            let wall = Int(date.timeIntervalSince1970 * 1000)
            self.append(self.bleFile, "\(wall),\(csvEscape(name)),\(uuid),\(rssi)")
            DispatchQueue.main.async { self.nBle += 1 }
        }
        scanner.start()

        isRecording = true
        status = "Recording '\(sessionName)'"
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        scanner.stop()
        for f in [tapsFile, rawFile, gestFile, bleFile, trialsFile] { try? f?.close() }
        tapsFile = nil; rawFile = nil; gestFile = nil; bleFile = nil; trialsFile = nil
        status = "Saved \(nTaps) taps, \(nGestures) gestures, \(nBle) BLE → \(sessionName)"
    }

    // MARK: - Touch ingestion (called from TouchRecognizer on the main thread)

    func ingest(_ t: UITouch) {
        let wall = Int(Date().timeIntervalSince1970 * 1000)
        let kts = t.timestamp                          // seconds since boot (monotonic)
        let p = t.location(in: nil)                    // window coordinates, points
        let x = Double(p.x), y = Double(p.y)
        let id = ObjectIdentifier(t)

        let phaseStr: String
        switch t.phase {
        case .began:      phaseStr = "began"
        case .moved:      phaseStr = "moved"
        case .stationary: phaseStr = "stationary"
        case .ended:      phaseStr = "ended"
        case .cancelled:  phaseStr = "cancelled"
        default:          phaseStr = "other"   // regionEntered/Moved/Exited etc.
        }

        let slot = touchSlot[id] ?? { let s = nextSlot; nextSlot += 1; touchSlot[id] = s; return s }()
        append(rawFile, "\(wall),\(fmt6(kts)),\(slot),\(phaseStr),"
               + "\(Int(x.rounded())),\(Int(y.rounded())),"
               + "\(fmt3(Double(t.force))),\(fmt3(Double(t.majorRadius))),\(studyPhase)")

        switch t.phase {
        case .began:
            append(tapsFile, "\(wall),\(fmt6(kts)),\(Int(x.rounded())),\(Int(y.rounded()))")
            nTaps += 1
            onTouchDown?(wall)
            assembler.began(id, x, y, kts, wall)
        case .moved:
            assembler.moved(id, x, y, kts)
        case .ended, .cancelled:
            assembler.ended(id, x, y, kts)
            touchSlot[id] = nil
        default:
            break
        }
    }

    // MARK: - Study outputs

    func writeTrialRow(_ row: String) { append(trialsFile, row) }

    /// The schedule as actually run, and the session metadata, both beside the CSVs
    /// so a dataset is self-describing rather than depending on remembered settings.
    func writeSessionFiles(schedule: Schedule, preset: String) {
        guard let dir = sessionDir else { return }
        if let d = schedule.jsonData() {
            try? d.write(to: dir.appendingPathComponent(sessionName + "_schedule.json"))
        }
        let meta: [String: Any] = [
            "session": sessionName,
            "platform": "ios",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "device_model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "preset": preset,
            "seed": String(schedule.seed),
            "started_wall_ms": TrialRunner.nowMs(),
            "note_required_fields": "watch_wrist / interacting_hand / posture / orientation "
                + "must be filled in before analysis - see GESTURE_STUDY_SPEC.md 7",
            "watch_wrist": "",
            "interacting_hand": "",
            "posture": "",
            "tablet_orientation": ""
        ]
        if let d = try? JSONSerialization.data(withJSONObject: meta,
                                               options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: dir.appendingPathComponent(sessionName + "_session.json"))
        }
    }

    // MARK: - File helpers

    private func openFile(_ dir: URL, _ suffix: String, header: String) -> FileHandle? {
        let url = dir.appendingPathComponent(sessionName + suffix)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.write((header + "\n").data(using: .utf8)!)
        return h
    }

    private func append(_ handle: FileHandle?, _ line: String) {
        handle?.write((line + "\n").data(using: .utf8)!)
    }
}

private func fmt6(_ v: Double) -> String { String(format: "%.6f", v) }
private func fmt3(_ v: Double) -> String { String(format: "%.3f", v) }
private func csvEscape(_ s: String) -> String {
    (s.contains(",") || s.contains("\"")) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
}
