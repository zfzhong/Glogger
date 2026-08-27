//
//  ContentView.swift
//  Operator controls + the three study-phase screens. The TouchLoggerView in the
//  background captures every touch across all of these while recording.
//
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var recorder: Recorder
    @StateObject private var runner = TrialRunner()
    @StateObject private var uploader = Uploader()
    @StateObject private var config = Config()
    @StateObject private var server = ServerClient()
    @State private var showShare = false
    @State private var showConfig = false
    @State private var studyMode = true
    /// The play downloaded for the chosen experiment. nil means the run will
    /// fall back to generating one on the device.
    @State private var loadedPlay: Play?
    @State private var playStatus = ""

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            phaseContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TouchLoggerView(recorder: recorder))   // app-wide passive capture
        .onAppear {
            // Route touches and classified gestures into the trial state machine.
            recorder.onTouchDown = { [weak runner] wall in runner?.touchDown(wallMs: wall) }
            recorder.onGestureRecord = { [weak runner] rec in runner?.gesture(rec) }
            runner.onRow = { [weak recorder] row in recorder?.writeTrialRow(row) }
            runner.onDeckRow = { [weak recorder] row in recorder?.writeDeckRow(row) }
            UIApplication.shared.isIdleTimerDisabled = true   // never sleep mid-session
            recorder.advertiseName = config.advertiseName
            // Show the cached play immediately; the network refresh can be slow
            // or absent, and the operator should still see what would run.
            if config.hasExperiment { loadedPlay = server.cached(config.experimentId) }
            Task {
                await server.loadExperiments(base: config.serverBase)
                if config.hasExperiment {
                    let (s, msg) = await server.fetchPlay(base: config.serverBase,
                                                              experimentId: config.experimentId)
                    if let s { loadedPlay = s }
                    playStatus = msg
                }
            }
            // Test hook: lets a simulator run drive the study without a human tap.
            if ProcessInfo.processInfo.arguments.contains("-autostart") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { startStudy() }
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showConfig) {
            ConfigView(config: config, server: server, recorder: recorder,
                       loadedPlay: $loadedPlay, playStatus: $playStatus)
                .onDisappear { recorder.advertiseName = config.advertiseName }
        }
        .sheet(isPresented: $showShare) {
            if let dir = recorder.sessionDir {
                ShareSheet(items: csvURLs(in: dir))
            }
        }
    }

    // MARK: Controls

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                TextField("Session name", text: $recorder.sessionName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                    .disabled(recorder.isRecording)

                // Guided study drives recording itself, so a separate record
                // button there was a second way to start the same thing. It only
                // earns its place in Free phases, where there is no study.
                if !studyMode {
                    if recorder.isRecording {
                        Button(role: .destructive) { recorder.stop() } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }.buttonStyle(.borderedProminent)
                    } else {
                        Button { recorder.start() } label: {
                            Label("Start", systemImage: "record.circle")
                        }.buttonStyle(.borderedProminent)
                    }
                }

                Toggle("Advertise", isOn: $recorder.advertise)
                    .toggleStyle(.switch).fixedSize()
                    .disabled(recorder.isRecording)

                Button { showConfig = true } label: {
                    Label("Configure", systemImage: "gearshape")
                }
                .disabled(recorder.isRecording)

                Button { showShare = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(recorder.isRecording || recorder.sessionDir == nil)

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
                }
                .disabled(recorder.isRecording || recorder.sessionDir == nil || uploader.busy)

                Spacer()
                Text("taps \(recorder.nTaps)   gest \(recorder.nGestures)   BLE \(recorder.nBle)   IMU \(recorder.nImu)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // What this run will actually do - the two things worth getting wrong.
            HStack(spacing: 10) {
                Image(systemName: config.hasExperiment ? "flask.fill" : "flask")
                    .foregroundStyle(config.hasExperiment ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(config.hasExperiment ? config.experimentName : "no experiment")
                    .fontWeight(config.hasExperiment ? .semibold : .regular)
                    .foregroundStyle(config.hasExperiment ? .primary : .secondary)

                if let s = loadedPlay {
                    Text("· \(s.name) · \(s.trials.count) trials")
                        .foregroundStyle(.secondary)
                } else if config.hasExperiment {
                    Text("· no play — will generate \(config.fallbackPreset) on device")
                        .foregroundStyle(.orange)
                } else {
                    Text("· will generate \(config.fallbackPreset) on device")
                        .foregroundStyle(.secondary)
                }

                if !config.missingMetadata.isEmpty {
                    Label(config.missingMetadata.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !uploader.progress.isEmpty {
                    Text(uploader.progress)
                        .foregroundStyle(uploader.progress.contains("FAILED") ? .orange : .secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .font(.caption)

            HStack {
                Circle().fill(recorder.isRecording ? .red : .gray).frame(width: 10, height: 10)
                Text(recorder.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Mode", selection: $studyMode) {
                    Text("Guided study").tag(true)
                    Text("Free phases").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .disabled(runner.isRunning)

                if studyMode {
                    // Recording and the trial sequence are one action here. Keyed
                    // on isRecording rather than runner.isRunning so the button
                    // still offers Stop after the last trial - recording carries on
                    // until it is stopped, and Upload needs it stopped.
                    if recorder.isRecording {
                        Button(role: .destructive) {
                            runner.abort()
                            recorder.stop()
                        } label: {
                            Label(runner.isRunning ? "Stop study" : "Stop recording",
                                  systemImage: "stop.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button { startStudy() } label: {
                            Label("Start study", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(uploader.busy)
                    }
                } else {
                    Picker("Phase", selection: $recorder.studyPhase) {
                        Text("1 · Browse").tag(0)
                        Text("2 · Type").tag(1)
                        Text("3 · Tap grid").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
            }
        }
        .padding(12)
    }

    // MARK: Phase screens

    /// Prefers the play downloaded for the chosen experiment; falls back to
    /// generating one on the device so a run is never blocked by the network.
    private func startStudy() {
        let play: Play
        let presetLabel: String
        if let s = loadedPlay {
            play = s
            presetLabel = "server:" + s.name
        } else {
            let seed = UInt64(config.fallbackSeed.trimmingCharacters(in: .whitespaces)) ?? 20260826
            let p = Preset(rawValue: config.fallbackPreset) ?? .demo
            play = Play.make(preset: p, seed: seed)
            presetLabel = p.rawValue
        }
        if !recorder.isRecording { recorder.start() }
        recorder.writeSessionFiles(play: play, preset: presetLabel, meta: config.snapshot())
        runner.start(play)
    }

    @ViewBuilder private var phaseContent: some View {
        if studyMode {
            StudyView(runner: runner) { [weak runner] ev, detail in
                recorder.writeWebRow(trial: runner?.index ?? -1, event: ev, detail: detail)
            }
        } else {
            freePhaseContent
        }
    }

    @ViewBuilder private var freePhaseContent: some View {
        switch recorder.studyPhase {
        case 0: BrowsePhase()
        case 1: TypePhase()
        default: TapGridPhase()
        }
    }
}

/// Phase 1 — scrollable feed (produces scroll + tap touches, like video browsing).
private struct BrowsePhase: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(0..<40, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(hue: Double(i % 10) / 10.0, saturation: 0.35, brightness: 0.9))
                        .frame(height: 150)
                        .overlay(Text("Card \(i + 1)").font(.title2).foregroundStyle(.white))
                }
            }
            .padding()
        }
    }
}

/// Phase 2 — typing (motion-rich keyboard interaction).
private struct TypePhase: View {
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading) {
            Text("Type a few sentences — the on-screen keyboard taps are logged.")
                .foregroundStyle(.secondary).padding(.horizontal)
            TextEditor(text: $text)
                .font(.title3)
                .padding()
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.3)))
                .padding()
        }
    }
}

/// Phase 3 — tap grid (clean discrete taps + occasional long-press).
private struct TapGridPhase: View {
    @State private var on = Set<Int>()
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(0..<48, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 10)
                        .fill(on.contains(i) ? Color.accentColor : Color.gray.opacity(0.2))
                        .frame(height: 90)
                        .onTapGesture { if on.contains(i) { on.remove(i) } else { on.insert(i) } }
                }
            }
            .padding()
        }
    }
}

// MARK: - Share sheet

private func csvURLs(in dir: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "csv" } ?? []
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
