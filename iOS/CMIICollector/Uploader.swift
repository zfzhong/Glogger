//
//  Uploader.swift
//  Ships a finished session to the collection server so the data survives the
//  app being deleted, the device being wiped, or simply never being plugged in.
//
//  One multipart POST per file to <base>/cmii/upload/. The server keys on
//  (session, filename, sha256), so uploading twice is harmless and a partly
//  failed upload is fixed by pressing Upload again — worth knowing, because the
//  IMU files are ~400 KB each and a flaky network mid-session is likely.
//
import Foundation
import UIKit

@MainActor
final class Uploader: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var progress = ""          // shown in the control bar

    /// Cleared when a new session starts, so the summary never shows the previous
    /// participant's upload result next to this participant's counts.
    func clearProgress() { progress = "" }

    /// Uploads every file in `dir`. `meta` is attached to the first request so the
    /// server can record participant / study / device without a second endpoint.
    func upload(dir: URL, session: String, base: String,
                study: String, participant: String, token: String?,
                experimentId: Int = 0) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        var root = base.trimmingCharacters(in: .whitespaces)
        if root.hasSuffix("/") { root.removeLast() }
        guard let url = URL(string: root + "/cmii/upload/") else {
            progress = "bad server URL"; return
        }

        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["csv", "json"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !files.isEmpty else { progress = "nothing to upload"; return }

        var ok = 0, dup = 0, failed = 0
        for (i, f) in files.enumerated() {
            progress = "uploading \(i + 1)/\(files.count) — \(f.lastPathComponent)"
            switch await post(url: url, file: f, session: session, study: study,
                              participant: participant, token: token,
                              experimentId: experimentId) {
            case "stored":    ok += 1
            case "duplicate": dup += 1
            default:          failed += 1
            }
        }
        progress = failed == 0
            ? "uploaded \(ok) file\(ok == 1 ? "" : "s")\(dup > 0 ? ", \(dup) already there" : "")"
            : "uploaded \(ok), \(dup) dup, ⚠️ \(failed) FAILED — press Upload again"
    }

    private func post(url: URL, file: URL, session: String, study: String,
                      participant: String, token: String?,
                      experimentId: Int) async -> String {
        guard let data = try? Data(contentsOf: file) else { return "read-error" }

        let boundary = "cmii-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            req.setValue(token, forHTTPHeaderField: "X-Upload-Token")
        }

        var body = Data()
        func field(_ name: String, _ value: String) {
            guard !value.isEmpty else { return }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("session", session)
        field("platform", "ios")
        field("device", UIDevice.current.model + " / iOS " + UIDevice.current.systemVersion)
        field("study", study)
        field("participant", participant)
        // Lets the server file this session under its experiment on arrival,
        // instead of it having to be grouped by hand afterwards.
        if experimentId > 0 { field("experiment", String(experimentId)) }

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.lastPathComponent)\"\r\n"
                    .data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        do {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return "http-error"
            }
            if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let status = obj["status"] as? String {
                return status
            }
            return "stored"
        } catch {
            return "network-error"
        }
    }
}
