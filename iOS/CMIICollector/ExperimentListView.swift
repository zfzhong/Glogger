//
//  ExperimentListView.swift
//  The landing screen: pick the experiment this participant is about to run.
//
//  The experiment is the one thing that changes every session, so it belongs on
//  the first screen rather than three taps into Configure - where it was easy to
//  start a run still bound to the previous participant's experiment.
//
//  Experiments that cannot run are shown greyed with the reason rather than
//  hidden. A misconfigured experiment that simply vanishes looks like it was
//  never created, and the operator hunts for it on the web instead of seeing
//  "no play assigned" printed on the row.
//
import SwiftUI

struct ExperimentListView: View {
    @ObservedObject var config: Config
    @ObservedObject var server: ServerClient
    @ObservedObject var recorder: Recorder
    /// Hands back the chosen experiment, the play, and how far into the play's
    /// timeline this tablet is joining. Zero when it is starting at the top.
    var onStart: (ExperimentInfo, Play, Int) -> Void

    @State private var loadingId: Int?
    /// Ticks so the countdown under each Start button stays honest without the
    /// operator having to pull to refresh.
    @State private var tick = Date()
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var failure = ""
    @State private var showConfig = false
    @State private var showFiles = false

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            if visible.isEmpty {
                empty
            } else {
                list
            }
        }
        .task { await refresh() }
        .onReceive(clock) { tick = $0 }
        .sheet(isPresented: $showFiles) {
            SessionFilesView(config: config)
        }
        .sheet(isPresented: $showConfig) {
            ConfigView(config: config, server: server, recorder: recorder)
                .onDisappear { recorder.advertiseName = config.advertiseName }
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose an experiment").font(.largeTitle.weight(.semibold))
                Spacer()
                // Sessions are never deleted, so the tablet holds the only
                // copy of anything that failed to upload. This is the way back
                // to one.
                Button { showFiles = true } label: {
                    Label("Files", systemImage: "folder")
                }
                Button { showConfig = true } label: {
                    Label("Configure", systemImage: "gearshape")
                }
            }

            HStack(spacing: 18) {
                // No role picker: the server assigns tablets, and a control that
                // could contradict it is only a way to be wrong.
                Text(config.deviceName.isEmpty ? "unnamed tablet" : config.deviceName)
                    .font(.callout)
                    .foregroundStyle(config.deviceName.isEmpty ? AnyShapeStyle(.orange)
                                                               : AnyShapeStyle(.secondary))

                Label(config.tabletRole == "B" ? config.advertiseName : "silent — decoy tablet",
                      systemImage: config.tabletRole == "B"
                          ? "dot.radiowaves.left.and.right" : "speaker.slash")
                    .font(.callout).foregroundStyle(.secondary)

                Spacer()

                if server.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }

            HStack(spacing: 14) {
                Text(server.status).font(.caption).foregroundStyle(.secondary)
                if server.clockKnown, abs(server.clockOffsetMs) >= 1000 {
                    Label("tablet clock off by \(server.clockOffsetMs / 1000)s — using server time",
                          systemImage: "clock.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !failure.isEmpty {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(20)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "flask").font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(server.busy ? "Loading…"
                 : hiddenCount > 0 ? "Nothing assigned to this tablet" : "No experiments")
                .font(.title3).foregroundStyle(.secondary)
            if hiddenCount > 0 && !server.busy {
                Text("\(hiddenCount) not assigned to this tablet")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            if !server.busy {
                Text("Create one on the server, then Refresh.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: List

    /// Only what this tablet can actually run: assigned to it, by name. An
    /// experiment with no device assigned is not ready, and one assigned to the
    /// other tablet is not this tablet's - both are noise at the bench.
    private var visible: [ExperimentInfo] {
        server.experiments.filter { $0.resolvedRole(for: config.deviceId) != nil }
    }

    private var hiddenCount: Int { server.experiments.count - visible.count }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(visible) { e in row(e) }
                if hiddenCount > 0 {
                    // Never silently: an experiment that is simply misassigned
                    // would otherwise look like it was never created.
                    Text("\(hiddenCount) hidden — assigned elsewhere, or no tablet assigned yet")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func row(_ e: ExperimentInfo) -> some View {
        let runnable = e.hasPlay
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(e.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(runnable ? .primary : .secondary)

                if !e.description.isEmpty {
                    Text(e.description).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if e.hasPlay {
                        Label(e.playName ?? "play", systemImage: "list.bullet.rectangle")
                        Text("\(e.trialCount) scenes")
                        if e.totalMsValue > 0 { Text(e.durationText) }
                        if e.tabletsValue > 1 { Text("2 tablets") }
                    } else {
                        Label(e.blockedReason, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // A free experiment skips every check the others enforce, so it
                // says so on the card. Nobody should reach the end of a sitting
                // and discover it was the test experiment.
                if e.free {
                    Text("free · testing — not participant data")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let mine = e.resolvedRole(for: config.deviceId) {
                    let beacons = e.advertises(for: config.deviceId)
                    Label(e.tabletsValue > 1
                          ? "plays \(mine) · " + (beacons ? "beacon" : "decoy, silent")
                          : "beacon",
                          systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                }

                if let missing = e.missing, !missing.isEmpty {
                    Label("not described on the server: " + missing.joined(separator: ", "),
                          systemImage: "person.crop.circle.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                }

                if e.sessions > 0 {
                    Text("\(e.sessions) session\(e.sessions == 1 ? "" : "s") already collected")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if loadingId == e.id {
                ProgressView().controlSize(.small).padding(.trailing, 6)
            } else {
                VStack(alignment: .trailing, spacing: 5) {
                    Button { Task { await start(e) } } label: {
                        Label("Start", systemImage: "play.fill").frame(minWidth: 74)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart(e) || loadingId != nil)

                    VStack(alignment: .trailing, spacing: 1) {
                        if let d = e.startDate {
                            Text(Self.clockText.string(from: d))
                                .font(.system(.caption, design: .monospaced))
                            Text(countdown(to: d))
                                .font(.caption2)
                                .foregroundStyle(canStart(e) ? AnyShapeStyle(.green)
                                                             : AnyShapeStyle(.secondary))
                        } else if e.tabletsValue > 1 {
                            Text("two tablets — needs a start time")
                                .font(.caption2).foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        } else {
                            Text("starts when you tap")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        .opacity(runnable ? 1 : 0.62)
    }

    // MARK: Actions

    private func refresh() async {
        failure = ""
        // Idempotent, so a tablet named on the web picks that up on the next
        // refresh rather than needing a restart.
        let b = UIScreen.main.nativeBounds
        if let seen = await server.register(
            base: config.serverBase, deviceId: config.deviceId,
            model: Config.hardwareModel,
            os: "iOS " + UIDevice.current.systemVersion,
            screen: "\(Int(b.width))x\(Int(b.height))") {
            config.deviceName = seen.name
            if !seen.advertise.isEmpty { config.advertiseName = seen.advertise }
        }
        await server.loadExperiments(base: config.serverBase)
    }

    private static let clockText: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    /// A two-tablet play REQUIRES a scheduled instant: it is the session's zero,
    /// and the only thing keeping the pair in step. A one-tablet play has nothing
    /// to stay in step with, so a start time is optional there - and when it has
    /// one, it is still honoured.
    ///
    /// Judged on server time, never the tablet's own.
    private func canStart(_ e: ExperimentInfo) -> Bool {
        guard e.hasPlay else { return false }
        // An assigned experiment names its tablets. This one may not be either -
        // the operator picked up the wrong tablet, or it was never assigned - and
        // running it would file the session under a role it does not have.
        guard e.resolvedRole(for: config.deviceId) != nil else { return false }
        // A future start time no longer disables the button, it changes what the
        // button does: the tablet arms and waits on a countdown. Disabling it
        // meant the only possible outcome was joining late.
        return true
    }

    private func countdown(to d: Date) -> String {
        let secs = Int(d.timeIntervalSince(server.serverNow()).rounded())
        if secs <= 0 {
            let ago = -secs
            if ago < 90 { return ago < 2 ? "now" : "running \(ago)s" }
            if ago < 5400 { return "running \(ago / 60) min" }
            return "began \(ago / 3600) h ago"
        }
        if secs < 90 { return "starts in \(secs)s" }
        if secs < 5400 { return "starts in \(secs / 60) min" }
        return "starts in \(secs / 3600) h"
    }

    private func start(_ e: ExperimentInfo) async {
        failure = ""
        loadingId = e.id
        defer { loadingId = nil }
        // Re-measure right before arming: the offset is what the countdown and
        // the two tablets' agreement both rest on.
        await server.syncClock(base: config.serverBase)
        let (play, msg) = await server.fetchPlay(base: config.serverBase, experimentId: e.id,
                                                 tablet: config.tabletRole)
        guard let play else { failure = msg; return }
        // Remember the choice so uploads and session.json agree with what ran,
        // even if the operator never opens Configure.
        config.experimentId = e.id
        config.experimentName = e.name
        config.adopt(e)
        // The assignment wins over the local picker, so two tablets can no longer
        // contradict each other about which half they are playing.
        config.tabletRole = e.resolvedRole(for: config.deviceId) ?? "B"
        config.advertise = e.advertises(for: config.deviceId)
        if let adv = e.advertiseName(for: config.deviceId), !adv.isEmpty {
            config.advertiseName = adv
        }
        // How far into the play's own timeline this tablet is arriving. The other
        // tablet computes the same number from the same instant, so both land on
        // the same scene however far apart the two button presses were.
        var joinedLateMs = 0
        if let d = e.startDate {
            joinedLateMs = max(0, Int(server.serverNow().timeIntervalSince(d) * 1000))
        }
        onStart(e, play, joinedLateMs)
    }
}
