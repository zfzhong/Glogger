//
//  Study.swift
//  Trial vocabulary, the play, and its seeded generator.
//
//  The play carries a FULLY MATERIALISED trial list rather than parameters to
//  be re-generated. Swift's and Kotlin's seeded PRNGs disagree, so generating per
//  platform would silently produce different designs from the same seed and break
//  cross-platform comparability (GESTURE_STUDY_SPEC.md §9b). Both apps play back
//  a stored list; SplitMix64 below is specified explicitly for the same reason.
//
import Foundation
import UIKit

/// Portable PRNG — identical output for a given seed on any platform.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Cardinal directions only.
///
/// Scenes no longer decode INTO this - a scene's `dir` is a plain string, because
/// the book also has IN/OUT and CW/CCW and a closed enum would fail to decode
/// them outright. This survives for the offline generator and for the geometry
/// check, which is only meaningful for the four cardinals anyway.
enum GDir: String, Codable, CaseIterable {
    case L, R, U, D
    var arrow: String {
        switch self {
        case .L: return "arrow.left"
        case .R: return "arrow.right"
        case .U: return "arrow.up"
        case .D: return "arrow.down"
        }
    }
    var word: String {
        switch self {
        case .L: return "left"
        case .R: return "right"
        case .U: return "up"
        case .D: return "down"
        }
    }
}

/// The built-in vocabulary.
///
/// This is NO LONGER what a scene is typed as - scenes carry a gesture slug as a
/// plain string plus the verb and accepted labels the server sends, so a gesture
/// added to the book on the web appears on the tablet with no app release. The
/// enum survives for the offline fallback generator and as a label of last resort
/// for a payload that predates the book.
enum GType: String, Codable, CaseIterable {
    case tap, double_tap, long_press, swipe, drag

    /// Direction is part of the class: swipe-left and swipe-up are different
    /// movements at the wrist, so they are scheduled and balanced separately.
    var directions: [GDir] { (self == .swipe || self == .drag) ? GDir.allCases : [] }

    var verb: String {
        switch self {
        case .tap:        return "Tap"
        case .double_tap: return "Tap twice"
        case .long_press: return "Press and hold"
        case .swipe:      return "Flick"
        case .drag:       return "Slowly drag"
        }
    }

    /// Gesture labels the on-device classifier may legitimately produce. Used only
    /// to VERIFY the trial — the cue is the label (see spec §2).
    var acceptedLabels: [String] {
        switch self {
        case .tap:        return ["tap"]
        case .double_tap: return ["tap"]          // two of them; handled separately
        case .long_press: return ["long_press"]
        case .swipe:      return ["swipe"]
        // Only "scroll" (slow displacement). Accepting "swipe" here made the match
        // flag meaningless: session 0824_0921 trial 0 cued a slow drag, the participant
        // flicked (200 ms / 167 px vs 1025-1117 ms for the real drags), and it still
        // scored as a match. The separation is clean, so the check should be strict.
        case .drag:       return ["scroll"]
        }
    }
}

/// One scene: a gesture cue, the grid it is shown in, the key block the
/// participant must act on, and how long they get.
///
/// rows/cols/durationMs are optional so a play generated before scenes
/// existed - including one sitting in the on-disk cache - still decodes; the
/// play-level values fill in.
/// One entry in a web scene's menu.
struct WebSite: Codable, Hashable, Identifiable {
    var label: String
    var url: String
    var id: String { url }
    /// Nil for anything that is not plain https - the tile is dropped rather than
    /// offering the participant a page that will not load.
    var link: URL? {
        guard let u = URL(string: url), u.scheme == "https" else { return nil }
        return u
    }
}

struct Trial: Codable, Identifiable {
    var i: Int
    /// Gesture slug from the book, e.g. "tap" or something added later.
    var type: String
    /// Direction code: L/R/U/D, or IN/OUT, CW/CCW for gestures that use them.
    var dir: String?
    var row: Int
    var col: Int
    var picture: String
    var rows: Int? = nil
    var cols: Int? = nil
    var durationMs: Int? = nil
    /// Sent by the server so an unknown gesture still renders and still scores.
    var verb: String? = nil
    var directional: Bool? = nil
    var acceptedLabels: [String]? = nil
    var tag: String? = nil
    var dirWord: String? = nil
    var dirIcon: String? = nil
    /// False for IN/OUT and CW/CCW: those cannot be checked against the stroke
    /// geometry, so the label alone decides the match.
    var dirVerifiable: Bool? = nil
    var affordance: String? = nil
    /// A travelling gesture ends on a different block. Drag does; a flick is
    /// ballistic and a scroll stays inside its own block.
    /// An off-screen scene asks for something away from the tablet - reaching for
    /// the water bottle, resting. The board is shadowed and inert and the screen
    /// carries the prompt instead of a cue.
    var offscreen: Bool? = nil
    /// A web scene hands the whole screen to a pinned page for its slot. The
    /// participant uses a real site; touches still land in this app's window, so
    /// they are still recorded, and the app stays foreground so the BLE beacon
    /// keeps advertising - neither of which is true of a real third-party app.
    var web: Bool? = nil
    var url: String? = nil
    /// A web scene may offer a menu instead of a single page. Free choice is part
    /// of what makes the session naturalistic; a bounded list keeps participants
    /// comparable and keeps uncurated content off the screen.
    var sites: [WebSite]? = nil
    var prompt: String? = nil
    var travels: Bool? = nil
    var toRow: Int? = nil
    var toCol: Int? = nil
    var toPicture: String? = nil
    /// Fixed-slot timing from the server: where this scene sits on the play's own
    /// timeline, and how long its slot is. Present from playVersion 3.
    var startMs: Int? = nil
    var slotMs: Int? = nil
    var gapMs: Int? = nil
    var id: Int { i }

    private var builtIn: GType? { GType(rawValue: type) }
    /// The cardinal direction, when this scene has one that geometry can check.
    var cardinal: GDir? { dir.flatMap { GDir(rawValue: $0) } }

    var directionWord: String {
        if let w = dirWord, !w.isEmpty { return w }
        return cardinal?.word ?? (dir ?? "").lowercased()
    }
    /// Validated on device: the server picks the symbol but cannot know what this
    /// iOS version renders, and an unknown name draws blank space next to the cue.
    var directionIcon: String? {
        if let i = dirIcon, !i.isEmpty, UIImage(systemName: i) != nil { return i }
        if let a = cardinal?.arrow, UIImage(systemName: a) != nil { return a }
        return nil
    }

    /// What the tablet shows. Falls back to the built-in verb, then the raw slug
    /// with underscores opened up, so a new gesture is never a blank cue.
    var displayVerb: String {
        if let v = verb, !v.isEmpty { return v }
        if let b = builtIn { return b.verb }
        return type.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// Classifier outputs that count as performing this gesture. Empty means the
    /// gesture cannot be auto-verified, and match is recorded as unknown rather
    /// than scoring every trial a failure.
    var labels: [String] {
        if let l = acceptedLabels { return l }
        return builtIn?.acceptedLabels ?? []
    }

    func grid(default s: Play) -> (rows: Int, cols: Int) {
        (max(1, rows ?? s.rows), max(1, cols ?? s.cols))
    }
    func block(default s: Play) -> Int { row * grid(default: s).cols + col }
    var isOffscreen: Bool { offscreen == true }
    var isWeb: Bool { web == true && (webURL != nil || !siteList.isEmpty) }
    var siteList: [WebSite] { (sites ?? []).filter { $0.link != nil } }
    var webURL: URL? {
        guard let u = url, !u.isEmpty, let parsed = URL(string: u),
              parsed.scheme == "https" else { return nil }
        return parsed
    }
    /// Neither kind of scene cues a gesture on the board, so both run their slot
    /// out on the clock instead of ending on a response.
    var isFreeform: Bool { isOffscreen || isWeb }
    var promptText: String {
        let p = (prompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? displayVerb : p
    }
    var isTravelling: Bool { travels == true && toRow != nil && toCol != nil }

    var cueText: String {
        if isOffscreen { return promptText }
        // A travelling scene shows its destination on screen, so naming the
        // direction as well is redundant - the target says where to go.
        if isTravelling { return displayVerb }
        guard dir != nil else { return displayVerb }
        return "\(displayVerb) \(directionWord)"
    }
}

enum Preset: String, CaseIterable, Identifiable {
    case demo, standard, full
    var id: String { rawValue }

    /// How many distinct blocks each (gesture, direction) condition is shown in.
    var blocksPerCondition: Int {
        switch self {
        case .demo: return 1
        case .standard: return 2
        case .full: return 4
        }
    }
    var title: String {
        switch self {
        case .demo:     return "Demo · 11"
        case .standard: return "Standard · 22"
        case .full:     return "Full · 44"
        }
    }
}

enum Animals {
    /// Filtered at runtime so a symbol missing on this iOS version cannot render blank.
    static let all: [String] = {
        let candidates = ["hare.fill", "tortoise.fill", "bird.fill", "fish.fill",
                          "ladybug.fill", "ant.fill", "lizard.fill", "cat.fill",
                          "dog.fill", "teddybear.fill", "pawprint.fill"]
        let ok = candidates.filter { UIImage(systemName: $0) != nil }
        return ok.count >= 4 ? ok : ["pawprint.fill", "hare.fill", "tortoise.fill", "ant.fill"]
    }()
}

struct Play: Codable {
    var playVersion = 3
    var name: String
    var seed: UInt64
    var rows = 2
    var cols = 2
    var readyMs = 800
    var cueTimeoutMs = 6000
    var gapMinMs = 1200
    var gapMaxMs = 2500
    var settleMs = 450
    var layouts: [String]? = nil
    var blockPictures: [String]
    var trials: [Trial]

    var count: Int { trials.count }

    /// Balanced: each (gesture, direction) condition appears in a different block on
    /// each repetition, so gesture type is never tied to screen position — at the
    /// wrist, reach location would otherwise dominate gesture identity (spec §2).
    static func make(preset: Preset, seed: UInt64) -> Play {
        var rng = SplitMix64(seed: seed)

        var pics = Animals.all
        pics.shuffle(using: &rng)
        let blockPics = Array(pics.prefix(4))

        var conditions: [(GType, GDir?)] = []
        for t in GType.allCases {
            if t.directions.isEmpty { conditions.append((t, nil)) }
            else { for d in t.directions { conditions.append((t, d)) } }
        }

        var out: [Trial] = []
        for rep in 0..<preset.blocksPerCondition {
            for (ci, c) in conditions.enumerated() {
                let b = (ci + rep) % 4
                out.append(Trial(i: 0, type: c.0.rawValue, dir: c.1?.rawValue,
                                 row: b / 2, col: b % 2, picture: blockPics[b],
                                 rows: 2, cols: 2,
                                 verb: c.0.verb,
                                 directional: !c.0.directions.isEmpty,
                                 acceptedLabels: c.0.acceptedLabels,
                                 tag: "normal",
                                 dirWord: c.1?.word, dirIcon: c.1?.arrow,
                                 dirVerifiable: true, affordance: "image"))
            }
        }
        out.shuffle(using: &rng)
        for i in out.indices { out[i].i = i }

        return Play(name: preset.rawValue, seed: seed,
                        blockPictures: blockPics, trials: out)
    }

    /// Swap out any SF Symbol this iOS version does not have.
    ///
    /// Block pictures are chosen on the server, which cannot know what this
    /// device can render - an unknown symbol name draws nothing, and the
    /// participant would be cued to tap an empty square.
    func sanitised() -> Play {
        var out = self
        let ok = Animals.all
        var swaps: [String: String] = [:]
        out.trials = trials   // replaced below if anything needs swapping
        out.blockPictures = blockPictures.enumerated().map { idx, nameIn in
            if UIImage(systemName: nameIn) != nil { return nameIn }
            let sub = ok[idx % ok.count]
            swaps[nameIn] = sub
            return sub
        }
        if !swaps.isEmpty {
            out.trials = trials.map { t in
                var t = t
                if let sub = swaps[t.picture] { t.picture = sub }
                if let tp = t.toPicture, let sub = swaps[tp] { t.toPicture = sub }
                return t
            }
        }
        return out
    }

    func jsonData() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(self)
    }
}
