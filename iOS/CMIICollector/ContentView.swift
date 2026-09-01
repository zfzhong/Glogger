//
//  ContentView.swift
//  Three screens, in the order a session actually happens: choose the
//  experiment, run it, see what was recorded.
//
//  It used to be one screen with a control bar and a mode picker, where the
//  experiment - the only thing that changes between participants - was hidden
//  inside Configure. A run could start bound to the previous participant's
//  experiment with nothing on screen contradicting it.
//
//  The old "Free phases" mode (browse / type / tap grid) is gone. It predates
//  plays, produced sessions with no cue and no server record of what was asked
//  for, and left two ways to start a recording where one will do.
//
import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @StateObject private var runner = TrialRunner()
    @StateObject private var uploader = Uploader()
    @StateObject private var config = Config()
    @StateObject private var server = ServerClient()

    private enum Screen { case list, armed, running, summary }
    @State private var screen: Screen = .list
    @State private var scenesTotal = 0
    /// Held between arming and the scheduled instant.
    @State private var pending: Play?
    @State private var startAt: Date?
    @State private var tick = Date()
    private let clock = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch screen {
            case .list:
                ExperimentListView(config: config, server: server, recorder: recorder) { _, play, at in
                    if let at {
                        arm(play, at: at)
                    } else {
                        recorder.start()
                        begin(play)
                    }
                }
            case .armed:
                armedScreen
            case .running:
                runningScreen
            case .summary:
                RunSummaryView(recorder: recorder, uploader: uploader, config: config,
                               scenesDone: runner.nDone, scenesTotal: scenesTotal) {
                    uploader.clearProgress()
                    recorder.sessionName = Recorder.defaultName()
                    screen = .list
                }
            }
        }
        .background(TouchLoggerView(recorder: recorder))   // app-wide passive capture
        .onAppear {
            recorder.onTouchDown = { [weak runner] wall in runner?.touchDown(wallMs: wall) }
            recorder.onGestureRecord = { [weak runner] rec in runner?.gesture(rec) }
            runner.onRow = { [weak recorder] row in recorder?.writeTrialRow(row) }
            runner.onDeckRow = { [weak recorder] row in recorder?.writeDeckRow(row) }
            UIApplication.shared.isIdleTimerDisabled = true   // never sleep mid-session
            recorder.advertiseName = config.advertiseName
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // The runner finishing is what ends a session, not the operator noticing
        // that it has. Recording is stopped here so the summary counts are final.
        .onChange(of: runner.phase) { _, p in
            if p == .done, screen == .running { finish() }
        }
        // Armed tablets begin on the clock, not on a person. Two tablets pressing
        // Start by hand are only as synchronised as the operator's two thumbs.
        .onReceive(clock) { now in
            tick = now
            guard screen == .armed, let at = startAt, let play = pending,
                  server.serverNow() >= at else { return }
            begin(play)
        }
    }

    // MARK: Running

    private var runningScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Circle().fill(recorder.isRecording ? .red : .gray).frame(width: 10, height: 10)
                Text(config.experimentName.isEmpty ? "Session" : config.experimentName)
                    .font(.headline)
                Text("Tablet \(config.tabletRole)")
                    .font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary))
                Text(recorder.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)

                Spacer()

                Text("touch \(recorder.nTaps)   gest \(recorder.nGestures)   BLE \(recorder.nBle)   IMU \(recorder.nImu)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button(role: .destructive) { finish() } label: {
                    Label(runner.isRunning ? "Stop" : "End session", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.bar)

            Divider()

            StudyView(runner: runner) { [weak runner] ev, detail in
                recorder.writeWebRow(trial: runner?.index ?? -1, event: ev, detail: detail)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Armed

    /// Recording starts at ARM, not at the scheduled instant, so the streams are
    /// already running when the play begins - a settled baseline before scene 0
    /// rather than a cold start, and the two tablets' BLE and IMU cover the same
    /// window even if one was armed earlier than the other.
    private func arm(_ play: Play, at: Date) {
        pending = play
        startAt = at
        scenesTotal = play.trials.count
        uploader.clearProgress()
        recorder.start()
        screen = .armed
    }

    private var armedScreen: some View {
        let remaining = max(0, (startAt ?? Date()).timeIntervalSince(server.serverNow()))
        return VStack(spacing: 22) {
            Spacer()
            Text(config.experimentName).font(.title2).foregroundStyle(.secondary)
            Text(Self.countdownText(remaining))
                .font(.system(size: 96, weight: .light, design: .monospaced))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text("Tablet \(config.tabletRole) · recording · starts on its own")
                .font(.callout).foregroundStyle(.secondary)
            if !server.clockKnown {
                Label("server time not measured — this tablet's own clock is being used",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            Spacer()
            HStack(spacing: 14) {
                Button("Start now") { if let p = pending { begin(p) } }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) {
                    recorder.stop()
                    pending = nil; startAt = nil
                    screen = .list
                } label: { Text("Cancel") }
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func countdownText(_ secs: TimeInterval) -> String {
        let t = Int(secs.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: Transitions

    private func begin(_ play: Play) {
        pending = nil; startAt = nil
        scenesTotal = play.trials.count
        if !recorder.isRecording { recorder.start() }
        recorder.writeSessionFiles(play: play, preset: "server:" + play.name,
                                   meta: config.snapshot(clockOffsetMs: server.clockOffsetMs,
                                                         clockKnown: server.clockKnown))
        runner.start(play)
        screen = .running
    }

    private func finish() {
        runner.abort()
        recorder.stop()
        screen = .summary
    }
}

// MARK: - Share sheet

func csvURLs(in dir: URL) -> [URL] {
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
