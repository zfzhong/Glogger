//
//  Study.swift
//  Trial vocabulary, the schedule, and its seeded generator.
//
//  The schedule carries a FULLY MATERIALISED trial list rather than parameters to
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

struct Trial: Codable, Identifiable {
    var i: Int
    var type: GType
    var dir: GDir?
    var row: Int
    var col: Int
    var picture: String
    var id: Int { i }

    var block: Int { row * 2 + col }
    var cueText: String {
        if let d = dir { return "\(type.verb) \(d.word)" }
        return type.verb
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

struct Schedule: Codable {
    var scheduleVersion = 2
    var name: String
    var seed: UInt64
    var rows = 2
    var cols = 2
    var readyMs = 800
    var cueTimeoutMs = 6000
    var gapMinMs = 1200
    var gapMaxMs = 2500
    var settleMs = 450
    var blockPictures: [String]
    var trials: [Trial]

    var count: Int { trials.count }

    /// Balanced: each (gesture, direction) condition appears in a different block on
    /// each repetition, so gesture type is never tied to screen position — at the
    /// wrist, reach location would otherwise dominate gesture identity (spec §2).
    static func make(preset: Preset, seed: UInt64) -> Schedule {
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
                out.append(Trial(i: 0, type: c.0, dir: c.1,
                                 row: b / 2, col: b % 2, picture: blockPics[b]))
            }
        }
        out.shuffle(using: &rng)
        for i in out.indices { out[i].i = i }

        return Schedule(name: preset.rawValue, seed: seed,
                        blockPictures: blockPics, trials: out)
    }

    func jsonData() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? e.encode(self)
    }
}
