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
    // Which device plays which half. A tablet matches its own id against these
    // rather than being told its role by hand.
    var tabletA: String? = nil
    var tabletB: String? = nil
    var tabletALabel: String? = nil
    var tabletBLabel: String? = nil
    var advertiseA: String? = nil
    var advertiseB: String? = nil
    /// "B", "A" or "both" - which tablet the watch scans for in this experiment.
    var beacon: String? = nil

    /// A testing experiment: every tablet lists it, it needs no schedule and no
    /// assignment, and its sessions are not participant data. Marked as such on
    /// the list, because it is the one experiment that skips every check.
    var free: Bool = false

    var hasPlay: Bool { (playId ?? 0) > 0 && trialCount > 0 }
    var hasAssignment: Bool { tabletA != nil || tabletB != nil }

    /// This device's half, or nil when it is not one of the assigned tablets.
    func role(for deviceId: String) -> String? {
        if deviceId == tabletA { return "A" }
        if deviceId == tabletB { return "B" }
        return nil
    }

    /// The advertise name for this device's half, as the server holds it.
    func advertiseName(for deviceId: String) -> String? {
        if deviceId == tabletA { return advertiseA }
        if deviceId == tabletB { return advertiseB }
        return nil
    }

    /// Whether THIS tablet is a beacon here.
    ///
    /// A single-tablet run always advertises: there is no decoy to contrast
    /// against, and a silent lone tablet leaves the watch with nothing.
    func advertises(for deviceId: String) -> Bool {
        if tabletsValue <= 1 { return true }
        // Free and unassigned: nobody is the decoy, so whoever picked it up is
        // the beacon. Otherwise a test looks like a BLE fault.
        if free, !hasAssignment { return true }
        guard let mine = role(for: deviceId) else { return false }
        let b = beacon ?? "B"
        return b == "both" || b == mine
    }

    /// What this tablet is for THIS experiment, or nil if it cannot run it.
    ///
    /// Assigned: the server decides. Unassigned single-tablet: there is no decoy,
    /// so the one tablet is the beacon. Unassigned two-tablet: refused - neither
    /// tablet can know which half it is, and guessing would either silence the
    /// beacon or duplicate it.
    func resolvedRole(for deviceId: String) -> String? {
        // A and B only mean anything when there are two. With one tablet there is
        // no decoy to contrast against, so it is the beacon whichever slot it was
        // assigned to - otherwise a single-tablet run assigned to slot A would go
        // silent and the watch would record nothing at all.
        // An experiment with no device assigned is not ready, whatever else is
        // set on it, so no tablet offers it - unless it is free, which is
        // exactly the experiment that exists to be picked up by anything. An
        // assignment is still honoured where one exists, so a free two-tablet
        // play can still be split deliberately.
        guard let mine = role(for: deviceId) else {
            return free ? (tabletsValue <= 1 ? "B" : "A") : nil
        }
        return tabletsValue <= 1 ? "B" : mine
    }

    var assignedTo: String {
        [tabletALabel.map { "A: \($0)" }, tabletBLabel.map { "B: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

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

    /// Announce this tablet, and learn what the server calls it.
    ///
    /// Cheap and idempotent, so it runs on every list refresh: a tablet named on
    /// the web picks that up without anyone restarting it.
    @discardableResult
    func register(base: String, deviceId: String, model: String,
                  os: String, screen: String) async -> (name: String, advertise: String)? {
        guard let url = URL(string: root(base) + "/cmii/device/register/") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        let fields = ["device_id": deviceId, "platform": "ios", "model": model,
                      "os_version": os, "screen": screen]
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Percent-encode conservatively: a model string like "iPad14,5" carries a
        // comma, which would otherwise arrive as a field separator.
        let encoded = fields.map { key, value -> String in
            let safe = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return key + "=" + safe
        }
        req.httpBody = encoded.joined(separator: "&").data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return (obj["name"] as? String ?? "", obj["advertiseName"] as? String ?? "")
        } catch { return nil }
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
    func fetchPlay(base: String, experimentId: Int, tablet: String = "A") async -> (Play?, String) {
        // The server cuts a two-tablet play in half and hands back this tablet's
        // side: same scene count, same slot boundaries, with the other tablet's
        // scenes replaced by empty ones. Ignored for a one-tablet play.
        let role = tablet.isEmpty ? "A" : tablet
        guard let url = URL(string: root(base)
                            + "/cmii/experiment/\(experimentId)/play.json?tablet=\(role)")
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
