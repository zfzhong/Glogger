//
//  ServerClient.swift
//  Fetches the experiment list and the trial play from the collection server.
//
//  Every successful play fetch is written to disk. A study run must never
//  depend on the network staying up between trials - and this iPad is known to
//  step its clock when it drops off wifi, so "carry on offline from the cached
//  copy" is the safe failure mode, not "stall mid-session".
//
import Foundation

struct ExperimentInfo: Codable, Identifiable, Hashable {
    var id: Int
    var name: String
    var description: String
    var sessions: Int
    var playId: Int?
    var playName: String?
    var trialCount: Int
    var totalMs: Int? = nil
    var tablets: Int? = nil
    var notes: String? = nil

    var hasPlay: Bool { (playId ?? 0) > 0 && trialCount > 0 }
    var totalMsValue: Int { totalMs ?? 0 }
    var tabletsValue: Int { tablets ?? 1 }

    /// Why Start is unavailable, in the operator's terms rather than the schema's.
    var blockedReason: String {
        if (playId ?? 0) == 0 { return "no play assigned" }
        if trialCount == 0 { return "its play has no scenes" }
        return ""
    }

    var durationText: String {
        let s = totalMsValue / 1000
        return s >= 60 ? "\(s / 60) min \(s % 60 == 0 ? "" : "\(s % 60) s")"
                       : "\(s) s"
    }
    var label: String {
        hasPlay ? "\(name) — \(playName ?? "?") (\(trialCount))"
                    : "\(name) — no play"
    }
}

private struct ExperimentList: Codable { var experiments: [ExperimentInfo] }

@MainActor
final class ServerClient: ObservableObject {
    @Published private(set) var experiments: [ExperimentInfo] = []
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private func root(_ base: String) -> String {
        var r = base.trimmingCharacters(in: .whitespaces)
        if r.hasSuffix("/") { r.removeLast() }
        return r
    }

    func loadExperiments(base: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        guard let url = URL(string: root(base) + "/cmii/experiments.json") else {
            status = "bad server URL"; return
        }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                status = "server returned an error"; return
            }
            experiments = try JSONDecoder().decode(ExperimentList.self, from: data).experiments
            try? data.write(to: listCacheURL())
            status = "\(experiments.count) experiment\(experiments.count == 1 ? "" : "s") · just now"
        } catch {
            // A dead network must not leave the operator staring at an empty
            // screen when the plays they need are already on this tablet.
            if experiments.isEmpty, let d = try? Data(contentsOf: listCacheURL()),
               let cached = try? JSONDecoder().decode(ExperimentList.self, from: d) {
                experiments = cached.experiments
                status = "offline — showing the last list this tablet saw"
            } else {
                status = "could not reach the server"
            }
        }
    }

    /// The play for one experiment, cached to disk under its id.
    func fetchPlay(base: String, experimentId: Int) async -> (Play?, String) {
        guard let url = URL(string: root(base) + "/cmii/experiment/\(experimentId)/play.json")
        else { return (nil, "bad server URL") }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return (cached(experimentId), "no response") }
            if http.statusCode == 404 {
                return (nil, "that experiment has no play assigned")
            }
            guard (200..<300).contains(http.statusCode) else {
                return (cached(experimentId), "server error \(http.statusCode)")
            }
            let play = try JSONDecoder().decode(Play.self, from: data).sanitised()
            try? data.write(to: cacheURL(experimentId))
            return (play, "fetched \(play.trials.count) trials")
        } catch {
            if let c = cached(experimentId) {
                return (c, "offline — using the cached copy (\(c.trials.count) trials)")
            }
            return (nil, "could not reach the server and nothing is cached")
        }
    }

    // MARK: cache

    private func listCacheURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("experiments.json")
    }

    private func cacheURL(_ experimentId: Int) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("play-exp\(experimentId).json")
    }

    func cached(_ experimentId: Int) -> Play? {
        guard let d = try? Data(contentsOf: cacheURL(experimentId)) else { return nil }
        return (try? JSONDecoder().decode(Play.self, from: d))?.sanitised()
    }
}
