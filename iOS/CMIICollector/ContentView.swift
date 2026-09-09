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

    /// The play downloaded and waiting for its scheduled instant.
    @State private var armedPlay: Play?
    @State private var armedStart: Date?
    @State private var armedRemaining: TimeInterval = 0

    /// One timer, owned for the whole armed period.
    ///
    /// It used to be an inline `Timer.publish(...).autoconnect()` inside the
    /// view body, which SwiftUI rebuilds on every body pass - and the body runs
    /// on every tick, and again on every @Published change from the recorder.
    /// Starting the pre-roll therefore tore down and replaced the very timer
    /// that was counting, and the countdown stopped dead at 0:10 while the
    /// recorder carried on happily in the background.
    @State private var armTicker: Timer?

    /// The pre-roll must happen once. `!recorder.isRecording` was the only
    /// guard, and a guard that depends on the thing it starts is a guard that
    /// fires twice if the start is not instantaneous.
    @State private var prerollStarted = false

    /// How long before the start the recorder and beacon come up.
    ///
    /// Not at the instant itself: the watch has to find the beacon before it can
    /// log anything, and a beacon that starts when scene 1 does costs the first
    /// seconds of the only signal that says which tablet was touched. Not at
    /// arming either - a tablet armed twenty minutes early would write twenty
    /// minutes of IMU before the session begins.
    private static let preroll: TimeInterval = 10

    var body: some View {
        Group {
            switch screen {
            case .list:
                ExperimentListView(config: config, server: server, recorder: recorder) { e, play, lateMs in
                    if let d = e.startDate, server.serverNow() < d {
                        // Still ahead of the instant: hold the play and let the
                        // clock start it, so two tablets set going by one pair of
                        // hands still begin together.
                        arm(play, at: d)
                    } else {
                        begin(play, joinedLateMs: lateMs)
                    }
                }
            case .armed:
                if let play = armedPlay {
                    ArmedView(play: play, experimentName: config.experimentName,
                              remaining: armedRemaining,
                              isRecording: recorder.isRecording,
                              clockKnown: server.clockKnown,
                              onCancel: cancelArmed)
                } else {
                    Color.clear.onAppear { screen = .list }
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
        startRecording(play)
        // Joining after the instant: the zero is still the schedule, just behind
        // us. Without a schedule at all it is the button press.
        runner.start(play, joinedLateMs: joinedLateMs)
        screen = .running
    }

    /// Hold a downloaded play until its scheduled instant.
    private func arm(_ play: Play, at date: Date) {
        armedPlay = play
        armedStart = date
        armedRemaining = date.timeIntervalSince(server.serverNow())
        scenesTotal = play.trials.count
        uploader.clearProgress()
        prerollStarted = false
        screen = .armed
        startArmTicker(play, at: date)
    }

    /// Ten ticks a second, not one: the start has to land on the instant, not on
    /// whenever this tablet's second happened to roll over, or two tablets are
    /// up to a second apart.
    ///
    /// Added to .common so the countdown keeps running while a finger is down on
    /// the screen - a participant resting a hand on the tablet must not be able
    /// to delay the start.
    private func startArmTicker(_ play: Play, at date: Date) {
        armTicker?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { _ in
            guard screen == .armed else { return }
            let left = date.timeIntervalSince(server.serverNow())
            armedRemaining = left
            if left <= Self.preroll, !prerollStarted {
                prerollStarted = true
                startRecording(play)
            }
            if left <= 0 { beginArmed(play) }
        }
        RunLoop.main.add(t, forMode: .common)
        armTicker = t
    }

    private func stopArmTicker() {
        armTicker?.invalidate()
        armTicker = nil
    }

    /// The instant arrived: the recorder is already running, so only run the play.
    private func beginArmed(_ play: Play) {
        guard screen == .armed else { return }
        stopArmTicker()
        if !recorder.isRecording { startRecording(play) }
        let at = armedStart
        armedPlay = nil; armedStart = nil
        // The scheduled instant, expressed on THIS device's clock. Both tablets
        // do the same conversion with their own measured offset, so both end up
        // with the same zero without ever comparing notes.
        let zero = at.map { Int($0.timeIntervalSince1970 * 1000) - server.clockOffsetMs }
        runner.start(play, joinedLateMs: 0, zeroDeviceMs: zero)
        screen = .running
    }

    private func cancelArmed() {
        stopArmTicker()
        prerollStarted = false
        armedPlay = nil; armedStart = nil
        // Whatever pre-roll was captured is not a session; drop it rather than
        // leaving a stub folder that looks like an aborted run.
        if recorder.isRecording { recorder.stop() }
        recorder.sessionName = Recorder.defaultName()
        screen = .list
    }

    /// Sensors, beacon and session files - everything except walking the play.
    ///
    /// Separate from begin() so an armed tablet can be recording, and its beacon
    /// discoverable, before the play starts.
    private func startRecording(_ play: Play) {
        // The experiment says which tablet is the beacon; the letter no longer
        // decides it. Set when the run was chosen, on the list screen.
        recorder.advertise = config.advertise
        recorder.start()
        recorder.writeSessionFiles(play: play, preset: "server:" + play.name,
                                   meta: config.snapshot(clockOffsetMs: server.clockOffsetMs,
                                                         clockKnown: server.clockKnown))
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
