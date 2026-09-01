//
//  RunSummaryView.swift
//  What was actually recorded, shown before the participant leaves the chair.
//
//  A session that recorded nothing is cheap to repeat while the person is still
//  sitting there and impossible to repeat afterwards. Two sessions have already
//  been lost to channels that failed silently, so every stream is listed with
//  its row count and an empty one is called out rather than left to be noticed
//  on the server later.
//
import SwiftUI

struct RunSummaryView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var uploader: Uploader
    @ObservedObject var config: Config
    let scenesDone: Int
    let scenesTotal: Int
    var onDone: () -> Void

    @State private var showShare = false

    /// Anything at zero is a channel that produced nothing at all.
    private var channels: [(String, Int, Bool)] {
        [("Touches",  recorder.nTaps,      true),
         ("Gestures", recorder.nGestures,  false),
         ("BLE",      recorder.nBle,       false),
         ("IMU",      recorder.nImu,       true)]
    }

    private var problems: [String] {
        var out: [String] = []
        for (name, n, required) in channels where n == 0 && required {
            out.append("\(name.lowercased()) recorded nothing")
        }
        if scenesTotal > 0 && scenesDone < scenesTotal {
            out.append("stopped after \(scenesDone) of \(scenesTotal) scenes")
        }
        return out
    }

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 7) {
                Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(problems.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.orange))
                Text(problems.isEmpty ? "Session recorded" : "Session recorded, with gaps")
                    .font(.title.weight(.semibold))
                Text(recorder.sessionName)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !config.experimentName.isEmpty {
                    Text(config.experimentName).font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                ForEach(channels, id: \.0) { name, n, _ in
                    VStack(spacing: 3) {
                        Text("\(n)")
                            .font(.system(.title2, design: .monospaced).weight(.medium))
                            .foregroundStyle(n == 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 96)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
                }
                VStack(spacing: 3) {
                    Text("\(scenesDone)/\(scenesTotal)")
                        .font(.system(.title2, design: .monospaced).weight(.medium))
                    Text("Scenes").font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 96)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
            }

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "circle.fill")
                            .font(.callout)
                            .labelStyle(BulletLabel())
                    }
                }
                .padding(14)
                .frame(maxWidth: 520, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
            }

            if !uploader.progress.isEmpty {
                Text(uploader.progress)
                    .font(.callout)
                    .foregroundStyle(uploader.progress.contains("FAILED") ? .orange : .secondary)
            }

            HStack(spacing: 14) {
                Button {
                    guard let dir = recorder.sessionDir else { return }
                    Task {
                        await uploader.upload(dir: dir, session: recorder.sessionName,
                                              base: config.serverBase, study: config.studyName,
                                              participant: config.participant,
                                              token: config.uploadToken.isEmpty ? nil : config.uploadToken,
                                              experimentId: config.experimentId)
                    }
                } label: {
                    Label(uploader.busy ? "Uploading…" : "Upload", systemImage: "icloud.and.arrow.up")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploader.busy || recorder.sessionDir == nil)

                Button { showShare = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(recorder.sessionDir == nil)

                Button(role: uploader.progress.isEmpty ? .cancel : nil, action: onDone) {
                    Text(uploader.progress.isEmpty ? "Done without uploading" : "Done")
                        .frame(minWidth: 90)
                }
                .disabled(uploader.busy)
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showShare) {
            if let dir = recorder.sessionDir { ShareSheet(items: csvURLs(in: dir)) }
        }
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 5)).foregroundStyle(.orange)
            configuration.title
        }
    }
}
