//
//  Config.swift
//  Every operator-set value in one place, persisted across launches.
//
//  These used to be scattered across the control bar as loose text fields, which
//  made the bar unreadable and meant the session-metadata fields the analysis
//  needs (wrist, hand, posture, orientation) had nowhere to live and shipped
//  empty in every session.json we have collected so far.
//
import Foundation
import SwiftUI

/// An immutable snapshot of the settings at the moment a run starts.
///
/// Recorder is not main-actor isolated and Config is, so the live object cannot
/// be handed across. Snapshotting also means a mid-run settings change cannot
/// alter what gets written into this session's metadata.
struct SessionMeta: Sendable {
    var experimentId = 0
    var experimentName = ""
    var advertiseName = ""
    var participant = ""
    var studyName = ""
    var watchWrist = ""
    var interactingHand = ""
    var posture = ""
    var tabletOrientation = ""
    var tabletRole = "A"
    var missing: [String] = []

    var hasExperiment: Bool { experimentId > 0 }
}

@MainActor
final class Config: ObservableObject {

    private func str(_ key: String, _ fallback: String) -> String {
        UserDefaults.standard.string(forKey: key) ?? fallback
    }
    private func put(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: Server
    // HTTPS on 443 avoids an App Transport Security exception, which plain
    // http:// would need.
    @Published var serverBase: String { didSet { put("serverBase", serverBase) } }
    @Published var uploadToken: String { didSet { put("uploadToken", uploadToken) } }

    // MARK: Experiment (chosen from the server; drives play + grouping)
    @Published var experimentId: Int {
        didSet { UserDefaults.standard.set(experimentId, forKey: "experimentId") }
    }
    @Published var experimentName: String { didSet { put("experimentName", experimentName) } }

    // MARK: BLE
    @Published var advertiseName: String { didSet { put("advertiseName", advertiseName) } }

    /// Which tablet this is in a two-tablet play. Both download the same play and
    /// follow the same timeline; the role decides whose scenes are whose.
    @Published var tabletRole: String { didSet { put("tabletRole", tabletRole) } }

    // MARK: Session metadata - required before analysis (spec §7)
    @Published var participant: String { didSet { put("participant", participant) } }
    @Published var studyName: String { didSet { put("studyName", studyName) } }
    @Published var watchWrist: String { didSet { put("watchWrist", watchWrist) } }
    @Published var interactingHand: String { didSet { put("interactingHand", interactingHand) } }
    @Published var posture: String { didSet { put("posture", posture) } }
    @Published var tabletOrientation: String { didSet { put("tabletOrientation", tabletOrientation) } }

    // MARK: Offline fallback - used only when no server play is available
    @Published var fallbackPreset: String { didSet { put("fallbackPreset", fallbackPreset) } }
    @Published var fallbackSeed: String { didSet { put("fallbackSeed", fallbackSeed) } }

    init() {
        let d = UserDefaults.standard
        serverBase        = d.string(forKey: "serverBase") ?? "https://withings.geosketch.art"
        uploadToken       = d.string(forKey: "uploadToken") ?? ""
        experimentId      = d.integer(forKey: "experimentId")          // 0 = none chosen
        experimentName    = d.string(forKey: "experimentName") ?? ""
        advertiseName     = d.string(forKey: "advertiseName") ?? "CMII-Pad"
        tabletRole        = d.string(forKey: "tabletRole") ?? "A"
        participant       = d.string(forKey: "participant") ?? ""
        studyName         = d.string(forKey: "studyName") ?? "elicitation"
        watchWrist        = d.string(forKey: "watchWrist") ?? ""
        interactingHand   = d.string(forKey: "interactingHand") ?? ""
        posture           = d.string(forKey: "posture") ?? ""
        tabletOrientation = d.string(forKey: "tabletOrientation") ?? ""
        fallbackPreset    = d.string(forKey: "fallbackPreset") ?? "demo"
        fallbackSeed      = d.string(forKey: "fallbackSeed") ?? "20260826"
    }

    var hasExperiment: Bool { experimentId > 0 }

    /// Fields the analysis needs that are still blank, so the operator can be
    /// warned before a run rather than after the data is on the server.
    var missingMetadata: [String] {
        var out: [String] = []
        if participant.isEmpty { out.append("participant") }
        if watchWrist.isEmpty { out.append("watch wrist") }
        if interactingHand.isEmpty { out.append("interacting hand") }
        if posture.isEmpty { out.append("posture") }
        if tabletOrientation.isEmpty { out.append("orientation") }
        return out
    }

    /// Freeze the current settings for one run.
    func snapshot() -> SessionMeta {
        SessionMeta(experimentId: experimentId, experimentName: experimentName,
                    advertiseName: advertiseName, participant: participant,
                    studyName: studyName, watchWrist: watchWrist,
                    interactingHand: interactingHand, posture: posture,
                    tabletOrientation: tabletOrientation, tabletRole: tabletRole,
                    missing: missingMetadata)
    }
}
