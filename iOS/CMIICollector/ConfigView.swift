//
//  ConfigView.swift
//  The operator's settings panel: server, experiment, BLE, session metadata.
//
import SwiftUI

struct ConfigView: View {
    @ObservedObject var config: Config
    @ObservedObject var server: ServerClient
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    /// Loaded when an experiment is picked, so the operator can see what will run.
    @Binding var loadedPlay: Play?
    @Binding var playStatus: String

    private let wrists = ["", "left", "right"]
    private let hands = ["", "left", "right"]
    private let postures = ["", "seated at table", "standing", "sofa", "in bed"]
    private let orientations = ["", "flat on table", "propped", "handheld"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://host", text: $config.serverBase)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("upload token (optional)", text: $config.uploadToken)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    HStack {
                        Button {
                            Task { await server.loadExperiments(base: config.serverBase) }
                        } label: {
                            Label(server.busy ? "Loading…" : "Refresh experiments",
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(server.busy)
                        Spacer()
                        Text(server.status).font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Experiment") {
                    if server.experiments.isEmpty {
                        Text(config.hasExperiment
                             ? "Currently: \(config.experimentName) (id \(config.experimentId)). Refresh to change."
                             : "Refresh to load the list from the server.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Picker("Experiment", selection: $config.experimentId) {
                            Text("— none (use the offline fallback) —").tag(0)
                            ForEach(server.experiments) { e in
                                Text(e.label).tag(e.id)
                            }
                        }
                        .onChange(of: config.experimentId) { _, newValue in
                            config.experimentName = server.experiments
                                .first { $0.id == newValue }?.name ?? ""
                            Task { await loadSchedule() }
                        }
                    }

                    if config.hasExperiment {
                        HStack {
                            Button {
                                Task { await loadSchedule() }
                            } label: { Label("Fetch play", systemImage: "arrow.down.circle") }
                            Spacer()
                        }
                        if let s = loadedPlay {
                            LabeledContent("Play", value: s.name)
                            LabeledContent("Trials", value: "\(s.trials.count)")
                            LabeledContent("Gap", value: "\(s.gapMinMs)–\(s.gapMaxMs) ms")
                        }
                        if !playStatus.isEmpty {
                            Text(playStatus).font(.caption)
                                .foregroundStyle(loadedPlay == nil ? .orange : .secondary)
                        }
                    }
                }

                Section("BLE") {
                    TextField("advertise name", text: $config.advertiseName)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text("The watch scans for this exact name — Slogger's filter is an exact match, so CMII-Pad-1 will not match CMII-Pad.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("scan name filter (blank = log everything)",
                              text: $recorder.bleFilter)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Text("Filters what this tablet's own scanner writes to _ble.csv. Left blank it logs every advertiser in range, including bystanders' phones and watches.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Session") {
                    TextField("participant", text: $config.participant)
                    TextField("study", text: $config.studyName)
                    Picker("Watch wrist", selection: $config.watchWrist) {
                        ForEach(wrists, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                    }
                    Picker("Interacting hand", selection: $config.interactingHand) {
                        ForEach(hands, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                    }
                    Picker("Posture", selection: $config.posture) {
                        ForEach(postures, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                    }
                    Picker("Tablet orientation", selection: $config.tabletOrientation) {
                        ForEach(orientations, id: \.self) { Text($0.isEmpty ? "—" : $0).tag($0) }
                    }
                    if !config.missingMetadata.isEmpty {
                        Label("Still blank: \(config.missingMetadata.joined(separator: ", "))",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Offline fallback") {
                    Picker("Preset", selection: $config.fallbackPreset) {
                        ForEach(Preset.allCases) { p in Text(p.title).tag(p.rawValue) }
                    }
                    TextField("seed", text: $config.fallbackSeed)
                        .keyboardType(.numberPad)
                    Text("Used only when no experiment is chosen, or the server has no play for it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func loadSchedule() async {
        guard config.hasExperiment else {
            loadedPlay = nil; playStatus = ""; return
        }
        let (s, msg) = await server.fetchPlay(base: config.serverBase,
                                                  experimentId: config.experimentId)
        loadedPlay = s
        playStatus = msg
    }
}
