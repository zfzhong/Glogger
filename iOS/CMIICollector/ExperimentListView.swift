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
    /// Hands back the chosen experiment and the play to run.
    var onStart: (ExperimentInfo, Play) -> Void

    @State private var loadingId: Int?
    @State private var failure = ""
    @State private var showConfig = false

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            if server.experiments.isEmpty {
                empty
            } else {
                list
            }
        }
        .task { await refresh() }
        .sheet(isPresented: $showConfig) {
            ConfigView(config: config, server: server, recorder: recorder,
                       loadedPlay: .constant(nil), playStatus: .constant(""))
                .onDisappear { recorder.advertiseName = config.advertiseName }
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose an experiment").font(.largeTitle.weight(.semibold))
                Spacer()
                Button { showConfig = true } label: {
                    Label("Configure", systemImage: "gearshape")
                }
            }

            HStack(spacing: 18) {
                // Which tablet this is. Both tablets download the same play and
                // run the same timeline; the role decides which scenes are this
                // tablet's and which it sits out showing an inert board.
                Picker("This tablet", selection: $config.tabletRole) {
                    Text("Tablet A").tag("A")
                    Text("Tablet B").tag("B")
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Label(config.advertiseName, systemImage: "dot.radiowaves.left.and.right")
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
                if !failure.isEmpty {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !config.missingMetadata.isEmpty {
                    Label("not set: " + config.missingMetadata.joined(separator: ", "),
                          systemImage: "person.crop.circle.badge.questionmark")
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
            Text(server.busy ? "Loading…" : "No experiments")
                .font(.title3).foregroundStyle(.secondary)
            if !server.busy {
                Text("Create one on the server, then Refresh.")
                    .font(.callout).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(server.experiments) { e in row(e) }
            }
            .padding(20)
        }
    }

    @ViewBuilder private func row(_ e: ExperimentInfo) -> some View {
        let runnable = e.hasPlay || server.cached(e.id) != nil
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
                    } else if server.cached(e.id) != nil {
                        Label("no play on the server — a cached copy is on this tablet",
                              systemImage: "internaldrive")
                            .foregroundStyle(.orange)
                    } else {
                        Label(e.blockedReason, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if e.sessions > 0 {
                    Text("\(e.sessions) session\(e.sessions == 1 ? "" : "s") already collected")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if loadingId == e.id {
                ProgressView().controlSize(.small).padding(.trailing, 6)
            } else {
                Button { Task { await start(e) } } label: {
                    Label("Start", systemImage: "play.fill").frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!runnable || loadingId != nil)
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
        await server.loadExperiments(base: config.serverBase)
    }

    private func start(_ e: ExperimentInfo) async {
        failure = ""
        loadingId = e.id
        defer { loadingId = nil }
        let (play, msg) = await server.fetchPlay(base: config.serverBase, experimentId: e.id)
        guard let play else { failure = msg; return }
        // Remember the choice so uploads and session.json agree with what ran,
        // even if the operator never opens Configure.
        config.experimentId = e.id
        config.experimentName = e.name
        onStart(e, play)
    }
}
