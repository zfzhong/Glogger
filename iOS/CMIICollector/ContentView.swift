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

    private enum Screen { case list, running, summary }
    @State private var screen: Screen = .list
    @State private var scenesTotal = 0

    var body: some View {
        Group {
            switch screen {
            case .list:
                ExperimentListView(config: config, server: server, recorder: recorder) { _, play, lateMs in
                    begin(play, joinedLateMs: lateMs)
                }
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
                if runner.skipped > 0 {
                    Label("joined late — \(runner.skipped) scene\(runner.skipped == 1 ? "" : "s") missed",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }

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

    // MARK: Transitions

    /// `joinedLateMs` is how far into the play's timeline this tablet is arriving.
    /// The schedule, not the button press, is the session's zero - see
    /// TrialRunner.start(_:joinedLateMs:).
    private func begin(_ play: Play, joinedLateMs: Int = 0) {
        scenesTotal = play.trials.count
        uploader.clearProgress()
        recorder.start()
        recorder.writeSessionFiles(play: play, preset: "server:" + play.name,
                                   meta: config.snapshot(clockOffsetMs: server.clockOffsetMs,
                                                         clockKnown: server.clockKnown))
        runner.start(play, joinedLateMs: joinedLateMs)
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
