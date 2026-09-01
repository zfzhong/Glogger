//
//  Recorder.swift
//  Session state + CSV writers. Produces, per session folder in Documents:
//
//    <name>_taps.csv          tablet_wall_ms,kernel_ts,x,y            (one row per touch-down)
//    <name>_touches_raw.csv   wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase,kbd
//                             kbd=1 means a keyboard was on screen and x,y are blank:
//                             coordinates over a keyboard are the text being typed.
//                             (full stream — the source-of-truth analog to getevent.log)
//    <name>_gestures.csv      14-col schema from GestureClassifier (matches the pipeline)
//    <name>_deck.csv          wall_ms,trial_idx,block,event,animal,to_block
//    <name>_web.csv           wall_ms,trial_idx,event,detail   (web scenes only)
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
    @Published var nImu = 0
    /// True while a system keyboard is on screen. Touch COORDINATES are withheld
    /// for the duration: on a keyboard they are the characters being typed, and
    /// this corpus includes recordings of children. Timing, duration and pressure
    /// are still recorded, which is what the wrist-side detector is trained
    /// against - so nothing the study needs is lost.
    private(set) var keyboardUp = false
    @Published var advertise = true          // tablet acts as the beacon for the watch
    /// Slogger on the watch filters by DEVICE NAME, not service UUID
    /// (EXPERIMENT_PROTOCOL.md §Software configuration), so this must match the
    /// name Slogger's scan filter is set to.
    @Published var advertiseName = "CMII-Pad"
    @Published private(set) var sessionDir: URL?

    /// Hooks for the study engine (set by ContentView). Called on the main thread.
    var onTouchDown: ((Int) -> Void)?
    var onGestureRecord: ((GestureRecord) -> Void)?

    private var tapsFile: FileHandle?
    private var trialsFile: FileHandle?
    private var rawFile: FileHandle?
    private var gestFile: FileHandle?
    private var deckFile: FileHandle?
    private var webFile: FileHandle?
    private var bleFile: FileHandle?

    private let scanner = BLEScanner()
    private let motion = MotionLogger()
    private let advertiser = BLEAdvertiser()
    private var accelFile: FileHandle?
    private var gyroFile: FileHandle?
    private var magFile: FileHandle?
    private let imuQueue = DispatchQueue(label: "cmii.imu.write")   // serialises IMU writes
    private let assembler = StrokeAssembler(thr: .default)
    private var touchSlot: [ObjectIdentifier: Int] = [:]   // stable small ids for the raw log
    private var nextSlot = 0

    init() { watchKeyboard() }

    /// `name`, or `name_2`, `name_3`... - the first that is not already holding
    /// a recorded session.
    static func freeName(_ name: String, under docs: URL) -> String {
        let fm = FileManager.default
        func taken(_ n: String) -> Bool {
            let d = docs.appendingPathComponent("sessions/\(n)", isDirectory: true)
            let items = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            return !items.isEmpty
        }
        if !taken(name) { return name }
        for i in 2...99 where !taken("\(name)_\(i)") { return "\(name)_\(i)" }
        return "\(name)_\(Int(Date().timeIntervalSince1970))"
    }

    static func defaultName() -> String {
        let f = DateFormatter(); f.dateFormat = "MMdd_HHmm"
        return f.string(from: Date())
    }

    // MARK: - Session lifecycle

    func start() {
        guard !isRecording else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // The default name is the launch minute, so a second run in the same
        // launch reused the same folder - and openFile truncates, so run 1 was
        // destroyed the instant run 2 started. It only survived once because it
        // had already been uploaded. Never reuse a folder that has files in it.
        sessionName = Recorder.freeName(sessionName, under: docs)
        let dir = docs.appendingPathComponent("sessions/\(sessionName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDir = dir

        tapsFile = openFile(dir, "_taps.csv",        header: "tablet_wall_ms,kernel_ts,x,y")
        rawFile  = openFile(dir, "_touches_raw.csv", header: "wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase,kbd")
        gestFile = openFile(dir, "_gestures.csv",    header: GestureRecord.header)
        // App-level ground truth: what the board actually did. Independent of the
        // classifier, which only ever infers from the stroke.
        // What a web scene actually showed. Without it a five-minute block of
        // touches has no record of what was under the finger.
        webFile  = openFile(dir, "_web.csv", header: "wall_ms,trial_idx,event,detail")
        deckFile = openFile(dir, "_deck.csv",
                            header: "wall_ms,trial_idx,block,event,animal,to_block")
        bleFile  = openFile(dir, "_ble.csv",         header: "wall_ms,name,uuid,rssi")
        trialsFile = openFile(dir, "_trials.csv",    header: TrialRunner.csvHeader)
        // One file per sensor, matching the watch-side convention (Pixel02_CMII_Accel_*).
        let imuHeader = "wall_ms,kernel_ts,x,y,z"
        accelFile = openFile(dir, "_imu_accel.csv", header: imuHeader)   // g, includes gravity
        gyroFile  = openFile(dir, "_imu_gyro.csv",  header: imuHeader)   // rad/s
        magFile   = openFile(dir, "_imu_mag.csv",   header: imuHeader)   // microtesla

        nTaps = 0; nGestures = 0; nBle = 0; nImu = 0
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

        motion.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
        motion.onSample = { [weak self] kind, wall, kts, x, y, z in
            guard let self else { return }
            let line = "\(wall),\(fmt6(kts)),\(fmt6(x)),\(fmt6(y)),\(fmt6(z))"
            // Off the main thread: at 100 Hz x 3 sensors this must not touch UI work.
            self.imuQueue.async {
                switch kind {
                case "accel": self.append(self.accelFile, line)
                case "gyro":  self.append(self.gyroFile, line)
                default:      self.append(self.magFile, line)
                }
            }
            // Throttle the counter — publishing 300x/s would stall SwiftUI.
            if self.motion.nSamples % 25 == 0 {
                let n = self.motion.nSamples
                DispatchQueue.main.async { self.nImu = n }
            }
        }
        motion.start()

        if advertise {
            advertiser.localName = advertiseName
            advertiser.onStatus = { [weak self] s in DispatchQueue.main.async { self?.status = s } }
            advertiser.start()
        }

        isRecording = true
        status = "Recording '\(sessionName)'"
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        scanner.stop()
        motion.stop()
        advertiser.stop()
        nImu = motion.nSamples
        imuQueue.sync { }                       // drain queued IMU writes before closing
        for f in [tapsFile, rawFile, gestFile, deckFile, webFile, bleFile, trialsFile,
                  accelFile, gyroFile, magFile] { try? f?.close() }
        tapsFile = nil; rawFile = nil; gestFile = nil; deckFile = nil; webFile = nil
        bleFile = nil; trialsFile = nil
        accelFile = nil; gyroFile = nil; magFile = nil
        status = "Saved \(nTaps) taps, \(nGestures) gestures, \(nBle) BLE, \(nImu) IMU → \(sessionName)"
    }

    // MARK: - Keyboard

    /// Watched for the whole life of the recorder, not just while recording, so
    /// the flag is already correct when a session starts with a keyboard up.
    private func watchKeyboard() {
        let c = NotificationCenter.default
        c.addObserver(forName: UIResponder.keyboardWillShowNotification,
                      object: nil, queue: .main) { [weak self] _ in self?.keyboardUp = true }
        c.addObserver(forName: UIResponder.keyboardDidHideNotification,
                      object: nil, queue: .main) { [weak self] _ in self?.keyboardUp = false }
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
        let xy = keyboardUp ? "," : "\(Int(x.rounded())),\(Int(y.rounded()))"
        append(rawFile, "\(wall),\(fmt6(kts)),\(slot),\(phaseStr),"
               + xy + ","
               + "\(fmt3(Double(t.force))),\(fmt3(Double(t.majorRadius))),\(studyPhase),"
               + (keyboardUp ? "1" : "0"))

        if keyboardUp {
            // The assembler would put x0,y0,x1,y1 into _gestures.csv, which is the
            // same disclosure by another route. Timing survives in the raw file.
            if t.phase == .began { nTaps += 1; onTouchDown?(wall) }
            if t.phase == .ended || t.phase == .cancelled { touchSlot[id] = nil }
            return
        }

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

    /// One row per thing the board did - a card flipped, discarded, carried away.
    func writeDeckRow(_ line: String) { append(deckFile, line) }

    /// One row per thing a web scene did - loaded a page, refused to leave the
    /// site, failed. Commas and newlines in a URL or an error message would split
    /// the row, so the detail is quoted.
    func writeWebRow(trial: Int, event: String, detail: String) {
        let safe = detail.replacingOccurrences(of: "\"", with: "\"\"")
        append(webFile, "\(Int(Date().timeIntervalSince1970 * 1000)),\(trial),\(event),\"\(safe)\"")
    }

    func writeTrialRow(_ row: String) { append(trialsFile, row) }

    /// The play as actually run, and the session metadata, both beside the CSVs
    /// so a dataset is self-describing rather than depending on remembered settings.
    /// Writes the two per-session sidecar files.
    ///
    /// `_play.json` is the as-run design: a snapshot of exactly what this
    /// session played. That is what makes it safe to edit a shared play on
    /// the server afterwards - already-collected sessions keep their own copy.
    func writeSessionFiles(play: Play, preset: String, meta info: SessionMeta) {
        guard let dir = sessionDir else { return }
        if let d = play.jsonData() {
            try? d.write(to: dir.appendingPathComponent(sessionName + "_play.json"))
        }
        var meta: [String: Any] = [
            "session": sessionName,
            "platform": "ios",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "device_model": UIDevice.current.model,
            "system_version": UIDevice.current.systemVersion,
            "preset": preset,
            "seed": String(play.seed),
            "play_name": play.name,
            "started_wall_ms": TrialRunner.nowMs(),
            "advertise_name": info.advertiseName,
            "participant": info.participant,
            "study": info.studyName,
            "watch_wrist": info.watchWrist,
            "interacting_hand": info.interactingHand,
            "posture": info.posture,
            "tablet_orientation": info.tabletOrientation,
            "tablet_role": info.tabletRole
        ]
        if info.hasExperiment {
            meta["experiment_id"] = info.experimentId
            meta["experiment_name"] = info.experimentName
        }
        let missing = info.missing
        if !missing.isEmpty {
            meta["note_missing_fields"] = "not filled in at record time: "
                + missing.joined(separator: ", ")
        }
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
