//
//  SessionFilesView.swift
//  Every session the tablet has ever recorded, and a way to send one again.
//
//  Sessions are never deleted, so the tablet holds the only copy of anything
//  that failed to upload. Until this screen existed there was no way back to
//  one: the summary appeared once, and dismissing it - or an upload that
//  silently did nothing, which is how this screen came to be written - stranded
//  the session where only a Mac with Xcode could reach it. A family's living
//  room does not have one of those.
//
//  Uploading is idempotent. The server keys on (session, filename, sha256), so
//  sending a session twice costs bandwidth and nothing else, and a partly
//  failed upload is repaired by sending the whole thing again.
//
import SwiftUI

struct SessionFilesView: View {
    let config: Config
    @StateObject private var uploader = Uploader()
    @State private var sessions: [SessionFolder] = []
    @State private var chosen: SessionFolder?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView("No sessions recorded",
                                           systemImage: "folder",
                                           description: Text("Runs appear here once the tablet has recorded one."))
                } else {
                    List(sessions) { s in
                        NavigationLink(value: s) {
                            row(s)
                        }
                    }
                }
            }
            .navigationTitle("Files")
            .navigationDestination(for: SessionFolder.self) { s in
                fileList(s)
            }
        }
        .task { sessions = SessionFolder.all() }
    }

    private func row(_ s: SessionFolder) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.name).font(.headline.monospacedDigit())
            HStack(spacing: 10) {
                Text("\(s.files.count) files")
                Text(s.sizeLabel)
                if let e = s.experimentName { Text(e) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: One session

    private func fileList(_ s: SessionFolder) -> some View {
        List {
            Section {
                ForEach(s.files, id: \.self) { f in
                    HStack {
                        Text(f.lastPathComponent).font(.callout.monospaced())
                        Spacer()
                        Text(SessionFolder.bytes(f)).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("\(s.files.count) files · \(s.sizeLabel)")
            } footer: {
                // The status line used to live only on the run summary and
                // vanished with it, so a failed upload left no trace of WHY.
                if !uploader.progress.isEmpty {
                    Text(uploader.progress).font(.callout)
                }
            }
        }
        .navigationTitle(s.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await send(s) }
                } label: {
                    if uploader.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Upload", systemImage: "icloud.and.arrow.up")
                    }
                }
                .disabled(uploader.busy)
            }
        }
    }

    /// Settings come from the session's own _session.json where it has them.
    ///
    /// A run recorded last week under a different participant must not be
    /// uploaded under today's config - the folder is a snapshot of what was
    /// actually run, and that is what should reach the server.
    private func send(_ s: SessionFolder) async {
        await uploader.upload(dir: s.url,
                              session: s.name,
                              base: config.serverBase,
                              study: s.meta["study"] as? String ?? config.studyName,
                              participant: s.meta["participant"] as? String ?? config.participant,
                              token: config.uploadToken.isEmpty ? nil : config.uploadToken,
                              experimentId: s.meta["experiment_id"] as? Int ?? 0,
                              deviceId: config.deviceId,
                              tabletRole: s.meta["tablet_role"] as? String ?? "")
    }
}

// MARK: - Model

struct SessionFolder: Identifiable, Hashable {
    let url: URL
    let name: String
    let files: [URL]
    let meta: [String: Any]

    var id: String { name }

    static func == (a: SessionFolder, b: SessionFolder) -> Bool { a.name == b.name }
    func hash(into h: inout Hasher) { h.combine(name) }

    var experimentName: String? { meta["experiment_name"] as? String }

    var totalBytes: Int {
        files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(totalBytes),
                                                      countStyle: .file) }

    static func bytes(_ f: URL) -> String {
        let n = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Newest first: the one you are looking for is almost always the last run.
    static func all() -> [SessionFolder] {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return [] }
        let root = docs.appendingPathComponent("sessions", isDirectory: true)
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { d in
                let files = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                    .filter { ["csv", "json"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                let metaURL = d.appendingPathComponent("\(d.lastPathComponent)_session.json")
                let meta = (try? Data(contentsOf: metaURL))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
                return SessionFolder(url: d, name: d.lastPathComponent, files: files, meta: meta)
            }
            .sorted { $0.name > $1.name }
    }
}
