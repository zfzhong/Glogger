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

    /// `joinedLateMs` lets a tablet enter a timeline that has already begun.
    ///
    /// The scheduled start of the experiment is the session's zero, not the
    /// moment someone pressed the button. Two tablets are pressed seconds apart
    /// by one pair of hands, and every scene owns a fixed slot - anchoring to the
    /// press instead of the schedule would leave them out of step by the gap
    /// between two thumbs, for the whole session.
    ///
    /// Scenes whose slot has already elapsed are skipped and recorded as
    /// "not_run", so the file still accounts for every scene in the play.
    func start(_ s: Play, joinedLateMs: Int = 0, zeroDeviceMs: Int? = nil) {
        play = s
        zeroMs = zeroDeviceMs ?? (Self.nowMs() - joinedLateMs)
        slotGen += 1
        index = 0; nDone = 0; nMatched = 0
        lastOutcome = ""; lastMatched = nil
        skipped = 0
        if joinedLateMs > 0 {
            var cursor = 0
            for (i, t) in s.trials.enumerated() {
                let slot = t.slotMs ?? (s.readyMs + (t.durationMs ?? s.cueTimeoutMs) + s.settleMs)
                let begins = t.startMs ?? cursor
                cursor = begins + slot
                if cursor > joinedLateMs { index = i; break }
                index = i + 1
                skipped = i + 1
                onRow?(Self.notRunRow(t))
            }
        }
        guard index < s.trials.count else { phase = .done; return }
        beginReady()
        startTicking()
    }

    /// Where scene `i` begins and ends, on this device's clock.
    private func slotStart(_ i: Int) -> Int {
        guard let s = play else { return zeroMs }
        var cursor = 0
        for (j, t) in s.trials.enumerated() {
            let begins = t.startMs ?? cursor
            if j == i { return zeroMs + begins }
            cursor = begins + slotLength(t, s)
        }
        return zeroMs + cursor
    }

    private func slotEnd(_ i: Int) -> Int {
        guard let s = play, i < s.trials.count else { return slotStart(i) }
        return slotStart(i) + slotLength(s.trials[i], s)
    }

    private func slotLength(_ t: Trial, _ s: Play) -> Int {
        t.slotMs ?? (s.readyMs + (t.durationMs ?? s.cueTimeoutMs) + s.settleMs)
    }

    /// Drives the countdown, ten times a second. Independent of the phase
    /// timers on purpose: if a scheduled callback is ever late, the number on
    /// screen still tells the truth about the slot.
    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            guard self.isRunning else { self.remainingMs = 0; t.invalidate(); return }
            self.remainingMs = max(0, self.slotEnd(self.index) - Self.nowMs())
        }
    }

    /// How many scenes were already over when this tablet joined.
    @Published private(set) var skipped = 0

    /// Milliseconds left in the scene now running, for the countdown on screen.
    ///
    /// Time left in the SLOT, not in the cue window: the scene is over when its
    /// slot is, whether or not the gesture was done in the first second.
    @Published private(set) var remainingMs = 0

    /// The play's own zero, on THIS device's clock.
    ///
    /// Every scene boundary is measured from here rather than from whenever the
    /// previous scene happened to end. Two tablets derive it from the same
    /// scheduled instant, each corrected by its own measured server offset, so
    /// they agree about when scene 7 begins without ever talking to each other.
    ///
    /// Device time, not server time: every timestamp in the CSVs is device time,
    /// and a file with two clocks in it cannot be aligned against the sensors.
    private var zeroMs = 0

    /// A second cancellation token, for the slot boundary alone. `gen` is bumped
    /// by every phase change, which cancels everything outstanding - right for
    /// the phase timers, fatal for the one callback that must survive them.
    private var slotGen = 0
    private var ticker: Timer?

    /// A scene the tablet was not running for. Same shape as a played row so the
    /// file has one row per scene either way.
    private static func notRunRow(_ t: Trial) -> String {
        "\(t.i),,\(t.row),\(t.col),\(t.type),\(t.dir ?? ""),\(t.picture),,,not_run,,,\(t.tag ?? "normal"),\(t.durationMs ?? 0),\(t.rows ?? 0),\(t.cols ?? 0)"
    }

    func abort() {
        gen += 1
        slotGen += 1
        ticker?.invalidate(); ticker = nil
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
        at(min(Self.nowMs() + s.settleMs, slotEnd(index)), gen) { [weak self] in
            self?.finish("completed")
        }
    }

    // MARK: - Phases

    private func beginReady() {
        guard let s = play, index < s.trials.count else { finishStudy(); return }
        collected = []; firstDownMs = nil; lastUpMs = nil; droppedOn = nil
        current = s.trials[index]
        displayTrial = current
        phase = .ready
        gen += 1
        // Anchored to the slot, not to "now": a scene that begins a little late
        // must still end on time, or the lateness accumulates down the play and
        // two tablets drift apart scene by scene.
        at(slotStart(index) + s.readyMs, gen) { [weak self] in self?.showCue() }
        atSlot(slotEnd(index)) { [weak self] in self?.closeSlot() }
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
        // "waiting" says this tablet was not the one playing; "elapsed" says it
        // was, and the window simply ran out. Both are non-events, but only one
        // of them means a scene went unanswered.
        let ending = current?.isWaiting == true ? "waiting"
                   : current?.isFreeform == true ? "elapsed" : "timeout"
        // The cue window is the shorter of what the scene asks for and what is
        // left of the slot; the slot is what actually ends the scene.
        at(min(Self.nowMs() + window, slotEnd(index)), gen) { [weak self] in
            self?.finish(ending)
        }
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

        // The row is written the moment the scene resolves, so the timing in the
        // file is the real timing - but the board waits out the rest of the slot
        // before moving on. Advancing early is what let two tablets wander
        // seconds apart, and what made the scene number jump before the
        // countdown reached zero.
        phase = .gap
    }

    /// The slot is over: the only thing that advances the scene.
    private func closeSlot() {
        guard let s = play else { return }
        // A scene still open when the slot ends - a slot shorter than the
        // window, or a callback that did not fire - is resolved here rather
        // than left unrecorded.
        if phase == .ready || phase == .cued || phase == .settling {
            let ending = current?.isWaiting == true ? "waiting"
                       : current?.isFreeform == true ? "elapsed" : "timeout"
            finish(ending)
        }
        gen += 1
        slotGen += 1
        index += 1
        if index >= s.trials.count { finishStudy() } else { beginReady() }
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

    /// Run at an absolute instant on this device's clock, or at once if past.
    private func at(_ whenMs: Int, _ token: Int, _ body: @escaping () -> Void) {
        after(max(0, whenMs - Self.nowMs()), token, body)
    }

    /// As `at`, but survives phase changes within the scene.
    private func atSlot(_ whenMs: Int, _ body: @escaping () -> Void) {
        let g = slotGen
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(max(0, whenMs - Self.nowMs()))
        ) { [weak self] in
            guard let self, g == self.slotGen else { return }
            body()
        }
    }

    private func after(_ ms: Int, _ token: Int, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { [weak self] in
            guard let self, self.gen == token else { return }
            body()
        }
    }
}
