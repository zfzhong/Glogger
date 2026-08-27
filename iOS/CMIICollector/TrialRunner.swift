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

    private(set) var play: Play?

    /// The scene the screen should be drawn for. Holds the last scene through the
    /// gap so the grid does not flicker back to the default between trials.
    @Published private(set) var displayTrial: Trial?

    /// One CSV row per finished trial.
    var onRow: ((String) -> Void)?
    var onDeckRow: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private var gen = 0                 // invalidates stale timers
    private var cueOnMs = 0
    private var firstDownMs: Int?
    private var lastUpMs: Int?
    private var collected: [GestureRecord] = []

    var total: Int { play?.count ?? 0 }
    var isRunning: Bool { phase != .idle && phase != .done }

    // match is 1 / 0 / empty. Empty means the cued gesture has no accepted
    // classifier labels in the book, so it cannot be auto-verified - which is not
    // the same as the participant getting it wrong.
    static let csvHeader = "trial_idx,cue_on_ms,block_row,block_col,cued_gesture,"
        + "cued_direction,picture_id,first_down_ms,last_up_ms,outcome,classified_gesture,match,"
        + "pace_tag,cue_duration_ms,grid_rows,grid_cols"

    // MARK: - Control

    func start(_ s: Play) {
        play = s
        index = 0; nDone = 0; nMatched = 0
        lastOutcome = ""; lastMatched = nil
        beginReady()
    }

    func abort() {
        gen += 1
        phase = .idle
        current = nil
        displayTrial = nil
        lastOutcome = ""
        lastMatched = nil
    }

    /// Where a dragged card actually landed, reported by the grid.
    ///
    /// This is app-level ground truth: the classifier can say "scroll" for a drag,
    /// but only the board knows whether the card reached the block the scene asked
    /// for. nil means it was thrown without landing anywhere.
    private(set) var droppedOn: Int?

    /// Emits a row and keeps the landing for scoring.
    func cardDropped(from: Int, to: Int?, animal: String) {
        droppedOn = to
        deckRow(block: from, event: to == nil ? "dropMissed" : "dropped",
                animal: animal, toBlock: to)
    }

    /// One row per thing the board did. This is the strongest evidence the
    /// intended interaction happened - stronger than the classifier, which only
    /// ever infers from the stroke.
    func deckRow(block: Int, event: String, animal: String, toBlock: Int? = nil) {
        onDeckRow?("\(Self.nowMs()),\(index),\(block),\(event),\(animal),"
                   + "\(toBlock.map(String.init) ?? "")")
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
        // An off-screen scene runs its whole slot: the participant is away from
        // the tablet, and a stray touch must not cut the window short.
        guard phase == .cued, let s = play, current?.isFreeform != true else { return }
        gen += 1                                   // cancel the cue timeout
        phase = .settling
        after(s.settleMs, gen) { [weak self] in self?.finish("completed") }
    }

    // MARK: - Phases

    private func beginReady() {
        guard let s = play, index < s.trials.count else { finishStudy(); return }
        collected = []; firstDownMs = nil; lastUpMs = nil; droppedOn = nil
        current = s.trials[index]
        displayTrial = current
        phase = .ready
        gen += 1
        after(s.readyMs, gen) { [weak self] in self?.showCue() }
    }

    private func showCue() {
        guard let s = play else { return }
        cueOnMs = Self.nowMs()
        lastOutcome = ""; lastMatched = nil
        phase = .cued
        gen += 1
        // Each scene carries its own response window; the play value is only
        // the fallback for a payload generated before scenes existed.
        let window = current?.durationMs ?? s.cueTimeoutMs
        // "timeout" would read as 22 failures in a session full of water breaks.
        // Nothing was expected on screen; the window simply ended.
        let ending = current?.isFreeform == true ? "elapsed" : "timeout"
        after(window, gen) { [weak self] in self?.finish(ending) }
    }

    private func finish(_ outcome: String) {
        guard let s = play, let t = current else { return }
        gen += 1

        var (observed, verdict) = Self.score(trial: t, gestures: collected)
        if let landed = landedCorrectly(t, s) { verdict = landed }
        // nil verdict = not verifiable, so it is neither a match nor a failure.
        let matched: Bool? = verdict.map { (outcome == "completed") && $0 }
        let g = t.grid(default: s)

        let row = "\(t.i),\(cueOnMs),\(t.row),\(t.col),\(t.type),"
            + "\(t.dir ?? ""),\(t.picture),"
            + "\(firstDownMs.map(String.init) ?? ""),\(lastUpMs.map(String.init) ?? ""),"
            + "\(outcome),\(observed),\(matched.map { $0 ? "1" : "0" } ?? ""),"
            + "\(t.tag ?? ""),\(t.durationMs ?? s.cueTimeoutMs),\(g.rows),\(g.cols)"
        onRow?(row)

        nDone += 1
        if matched == true { nMatched += 1 }
        lastMatched = matched
        lastOutcome = outcome == "timeout"
            ? "no gesture"
            : (matched == nil ? "recorded"
               : (matched == true ? "matched" : "got \(observed.isEmpty ? "nothing" : observed)"))

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

    /// Returns the observed label and a verdict. A nil verdict means the gesture
    /// has no accepted labels in the book and so cannot be auto-verified - the
    /// trial is still perfectly good data, it just is not scored.
    static func score(trial: Trial, gestures: [GestureRecord]) -> (String, Bool?) {
        let accepted = trial.labels
        guard !accepted.isEmpty else { return (gestures.first?.type ?? "", nil) }
        guard let first = gestures.first else { return ("", false) }

        if trial.type == GType.double_tap.rawValue {
            let taps = gestures.filter { $0.type == "tap" }.count
            return (taps >= 2 ? "double_tap" : first.type, taps >= 2)
        }

        var ok = accepted.contains(first.type)
        // Geometry can only adjudicate the cardinals. A pinch IN and a pinch OUT
        // both classify as "pinch"; checking them against dx/dy would reject
        // every one of them.
        if ok, trial.dirVerifiable != false, let d = trial.cardinal {
            ok = directionMatches(first, d)
        }
        return (first.type, ok)
    }

    /// For a travelling scene, where the card ended is better evidence than which
    /// way the stroke went: a short drag in roughly the right direction used to
    /// score as a match even if it stopped halfway.
    private func landedCorrectly(_ t: Trial, _ s: Play) -> Bool? {
        guard t.isTravelling, let want = t.toRow, let wantC = t.toCol else { return nil }
        guard let got = droppedOn else { return false }
        return got == want * t.grid(default: s).cols + wantC
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
