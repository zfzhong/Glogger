//
//  TrialRunner.swift
//  The trial state machine, shared by both studies (gesture elicitation now, the
//  PILOT_PROTOCOL discrimination study later — a study is just a trial vocabulary
//  plus a cue renderer).
//
//    ready ──▶ cue shown ──▶ (gesture) ──▶ settling ──▶ scored ──▶ gap ──▶ next
//                   └── no gesture within cueTimeoutMs ──▶ timeout ──▶ gap
//
//  `ready` is a quiet pre-cue window so the watch has a clean IMU baseline before
//  every gesture. `settling` briefly keeps collecting after the first gesture, so a
//  double-tap is seen as two taps rather than scored on the first one. The gap is
//  randomised so trials do not blur together in the IMU stream and the participant
//  cannot fall into a rhythm.
//
import Foundation
import SwiftUI

final class TrialRunner: ObservableObject {
    enum Phase: String { case idle, ready, cued, settling, gap, done }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var index = 0
    @Published private(set) var current: Trial?
    @Published private(set) var nDone = 0
    @Published private(set) var nMatched = 0
    @Published private(set) var lastOutcome = ""      // shown during the gap
    @Published private(set) var lastMatched: Bool?    // drives the block flash

    private(set) var schedule: Schedule?

    /// One CSV row per finished trial.
    var onRow: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private var gen = 0                 // invalidates stale timers
    private var cueOnMs = 0
    private var firstDownMs: Int?
    private var lastUpMs: Int?
    private var collected: [GestureRecord] = []

    var total: Int { schedule?.count ?? 0 }
    var isRunning: Bool { phase != .idle && phase != .done }

    static let csvHeader = "trial_idx,cue_on_ms,block_row,block_col,cued_gesture,"
        + "cued_direction,picture_id,first_down_ms,last_up_ms,outcome,classified_gesture,match"

    // MARK: - Control

    func start(_ s: Schedule) {
        schedule = s
        index = 0; nDone = 0; nMatched = 0
        lastOutcome = ""; lastMatched = nil
        beginReady()
    }

    func abort() {
        gen += 1
        phase = .idle
        current = nil
        lastOutcome = ""
        lastMatched = nil
    }

    // MARK: - Inputs from the Recorder (main thread)

    func touchDown(wallMs: Int) {
        guard phase == .cued else { return }
        if firstDownMs == nil { firstDownMs = wallMs }
    }

    func gesture(_ rec: GestureRecord) {
        guard phase == .cued || phase == .settling else { return }
        collected.append(rec)
        // GestureRecord.wallMs is when the stroke STARTED; the end is start + duration.
        // Using wallMs directly made first_down_ms == last_up_ms and left every trial
        // with a zero-width time window - useless for slicing the watch IMU stream.
        lastUpMs = rec.wallMs + Int(rec.durMs.rounded())
        guard phase == .cued, let s = schedule else { return }
        gen += 1                                   // cancel the cue timeout
        phase = .settling
        after(s.settleMs, gen) { [weak self] in self?.finish("completed") }
    }

    // MARK: - Phases

    private func beginReady() {
        guard let s = schedule, index < s.trials.count else { finishStudy(); return }
        collected = []; firstDownMs = nil; lastUpMs = nil
        current = s.trials[index]
        phase = .ready
        gen += 1
        after(s.readyMs, gen) { [weak self] in self?.showCue() }
    }

    private func showCue() {
        guard let s = schedule else { return }
        cueOnMs = Self.nowMs()
        lastOutcome = ""; lastMatched = nil
        phase = .cued
        gen += 1
        after(s.cueTimeoutMs, gen) { [weak self] in self?.finish("timeout") }
    }

    private func finish(_ outcome: String) {
        guard let s = schedule, let t = current else { return }
        gen += 1

        let (observed, ok) = Self.score(trial: t, gestures: collected)
        let matched = (outcome == "completed") && ok

        let row = "\(t.i),\(cueOnMs),\(t.row),\(t.col),\(t.type.rawValue),"
            + "\(t.dir?.rawValue ?? ""),\(t.picture),"
            + "\(firstDownMs.map(String.init) ?? ""),\(lastUpMs.map(String.init) ?? ""),"
            + "\(outcome),\(observed),\(matched ? 1 : 0)"
        onRow?(row)

        nDone += 1
        if matched { nMatched += 1 }
        lastMatched = matched
        lastOutcome = outcome == "timeout"
            ? "no gesture"
            : (matched ? "matched" : "got \(observed.isEmpty ? "nothing" : observed)")

        phase = .gap
        let gap = Int.random(in: s.gapMinMs...s.gapMaxMs)
        after(gap, gen) { [weak self] in
            guard let self else { return }
            self.index += 1
            if self.index >= self.total { self.finishStudy() } else { self.beginReady() }
        }
    }

    private func finishStudy() {
        gen += 1
        phase = .done
        current = nil
        onFinished?()
    }

    // MARK: - Scoring (verification only — the cue is the label)

    static func score(trial: Trial, gestures: [GestureRecord]) -> (String, Bool) {
        guard let first = gestures.first else { return ("", false) }

        if trial.type == .double_tap {
            let taps = gestures.filter { $0.type == "tap" }.count
            return (taps >= 2 ? "double_tap" : first.type, taps >= 2)
        }

        var ok = trial.type.acceptedLabels.contains(first.type)
        if ok, let d = trial.dir { ok = directionMatches(first, d) }
        return (first.type, ok)
    }

    static func directionMatches(_ g: GestureRecord, _ d: GDir) -> Bool {
        let dx = Double(g.x1 - g.x0), dy = Double(g.y1 - g.y0)   // iOS y grows downward
        if abs(dx) < 15 && abs(dy) < 15 { return false }
        switch d {
        case .L: return dx < 0 && abs(dx) > abs(dy)
        case .R: return dx > 0 && abs(dx) > abs(dy)
        case .U: return dy < 0 && abs(dy) > abs(dx)
        case .D: return dy > 0 && abs(dy) > abs(dx)
        }
    }

    // MARK: - Helpers

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func after(_ ms: Int, _ token: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
            guard let self, self.gen == token else { return }
            body()
        }
    }
}
