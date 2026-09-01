//
//  ConfigView.swift
//  The operator's settings panel: server, BLE, session metadata.
//
//  The experiment is NOT here. It changes every session and belongs on the
//  landing screen; having it in two places meant a run could be bound to one
//  experiment while the other screen showed another.
//
import SwiftUI

struct ConfigView: View {
    @ObservedObject var config: Config
    @ObservedObject var server: ServerClient
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

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

            }
            .navigationTitle("Configuration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

}
