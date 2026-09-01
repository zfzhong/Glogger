//
//  ServerClient.swift
//  Fetches the experiment list and the trial play from the collection server.
//
//  Wifi is a precondition for the bench - the whole configuration lives on the
//  server - so a play is always fetched fresh and a failed fetch is a hard stop.
//  Falling back to a copy on disk would let an operator run yesterday's play
//  after editing it on the web, with nothing on screen saying so.
//
//  The experiment LIST is still cached, because a momentary hiccup there only
//  decides whether the landing screen is blank; it can never cause a stale run.
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
    var startISO: String? = nil
    // The sitting, described once by the administrator. The tablet writes these
    // into session.json rather than asking for them to be typed twice.
    var participant: String? = nil
    var watchWrist: String? = nil
    var interactingHand: String? = nil
    var posture: String? = nil
    var tabletOrientation: String? = nil
    var missing: [String]? = nil

    var hasPlay: Bool { (playId ?? 0) > 0 && trialCount > 0 }
    var totalMsValue: Int { totalMs ?? 0 }
    var tabletsValue: Int { tablets ?? 1 }

    /// Why Start is unavailable, in the operator's terms rather than the schema's.
    var blockedReason: String {
        if (playId ?? 0) == 0 { return "no play assigned" }
        if trialCount == 0 { return "its play has no scenes" }
        return ""
    }

    /// When this experiment is scheduled to begin. Nil = run whenever.
    var startDate: Date? {
        guard let iso = startISO, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
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

    /// serverNow - deviceNow, in milliseconds. Two tablets arm against an
    /// absolute instant, and this iPad's clock steps by seconds when it drops off
    /// wifi, so every scheduled start is judged on server time rather than the
    /// device's own. Zero until measured; `clockKnown` says which.
    @Published private(set) var clockOffsetMs = 0
    @Published private(set) var clockKnown = false

    func deviceNowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }
    /// The device clock corrected onto the server's.
    func serverNowMs() -> Int { deviceNowMs() + clockOffsetMs }
    func serverNow() -> Date { Date(timeIntervalSince1970: Double(serverNowMs()) / 1000) }

    /// Round-trip compensated: the server's reading is assumed to have been taken
    /// halfway through the exchange, which is as good as this gets over HTTP.
    func syncClock(base: String) async {
        guard let url = URL(string: root(base) + "/cmii/now.json") else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let t0 = Date().timeIntervalSince1970
            let (data, _) = try await URLSession.shared.data(for: req)
            let t1 = Date().timeIntervalSince1970
            struct Now: Codable { var nowMs: Int }
            let server = try JSONDecoder().decode(Now.self, from: data).nowMs
            clockOffsetMs = server - Int((t0 + t1) / 2 * 1000)
            clockKnown = true
        } catch {
            // Leave the last known offset in place; a momentary failure should not
            // silently move every scheduled start by the size of the drift.
        }
    }

    private func root(_ base: String) -> String {
        var r = base.trimmingCharacters(in: .whitespaces)
        if r.hasSuffix("/") { r.removeLast() }
        return r
    }

    func loadExperiments(base: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await syncClock(base: base)
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

    /// The play for one experiment, always from the server.
    ///
    /// No disk fallback on purpose: the play is what the session IS, and running
    /// a stale one looks exactly like running the right one.
    func fetchPlay(base: String, experimentId: Int) async -> (Play?, String) {
        guard let url = URL(string: root(base) + "/cmii/experiment/\(experimentId)/play.json")
        else { return (nil, "bad server URL") }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return (nil, "no response from the server")
            }
            if http.statusCode == 404 {
                return (nil, "that experiment has no play assigned")
            }
            guard (200..<300).contains(http.statusCode) else {
                return (nil, "server error \(http.statusCode)")
            }
            let play = try JSONDecoder().decode(Play.self, from: data).sanitised()
            return (play, "fetched \(play.trials.count) trials")
        } catch {
            return (nil, "could not reach the server — check wifi and try again")
        }
    }

    // MARK: cache

    private func listCacheURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("experiments.json")
    }

}
