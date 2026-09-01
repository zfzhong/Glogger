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
                    // Participant, wrist, hand, posture and orientation describe the
                    // sitting, not this device, and are set on the experiment so both
                    // tablets cannot disagree. Shown read-only for confirmation.
                    TextField("study", text: $config.studyName)
                    LabeledContent("Participant",
                                   value: config.participant.isEmpty ? "—" : config.participant)
                    LabeledContent("Watch wrist",
                                   value: config.watchWrist.isEmpty ? "—" : config.watchWrist)
                    LabeledContent("Interacting hand",
                                   value: config.interactingHand.isEmpty ? "—" : config.interactingHand)
                    LabeledContent("Posture",
                                   value: config.posture.isEmpty ? "—" : config.posture)
                    LabeledContent("Tablet orientation",
                                   value: config.tabletOrientation.isEmpty ? "—" : config.tabletOrientation)
                    Text("Set on the experiment, on the server. This tablet adopts them when a run starts.")
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

}
