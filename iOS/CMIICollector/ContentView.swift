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
    @State private var showShare = false
    @State private var studyMode = true
    @State private var preset: Preset = .demo
    @State private var seedText = "20260826"

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
            UIApplication.shared.isIdleTimerDisabled = true   // never sleep mid-session
            // Test hook: lets a simulator run drive the study without a human tap.
            if ProcessInfo.processInfo.arguments.contains("-autostart") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { startStudy() }
            }
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
                    .frame(width: 180)
                    .disabled(recorder.isRecording)
                TextField("BLE name filter", text: $recorder.bleFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(recorder.isRecording)

                if recorder.isRecording {
                    Button(role: .destructive) { recorder.stop() } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button { recorder.start() } label: {
                        Label("Start", systemImage: "record.circle")
                    }.buttonStyle(.borderedProminent)
                }

                Toggle("Advertise", isOn: $recorder.advertise)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(recorder.isRecording)

                TextField("adv name", text: $recorder.advertiseName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .disabled(recorder.isRecording || !recorder.advertise)

                Button { showShare = true } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(recorder.isRecording || recorder.sessionDir == nil)

                Spacer()
                Text("taps \(recorder.nTaps)   gest \(recorder.nGestures)   BLE \(recorder.nBle)   IMU \(recorder.nImu)")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
                    Picker("Preset", selection: $preset) {
                        ForEach(Preset.allCases) { p in Text(p.title).tag(p) }
                    }
                    .pickerStyle(.menu)
                    .disabled(runner.isRunning)

                    TextField("seed", text: $seedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(runner.isRunning)

                    if runner.isRunning {
                        Button(role: .destructive) { runner.abort() } label: {
                            Label("Stop study", systemImage: "xmark.circle.fill")
                        }
                    } else {
                        Button { startStudy() } label: {
                            Label("Start study", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
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

    private func startStudy() {
        let seed = UInt64(seedText.trimmingCharacters(in: .whitespaces)) ?? 20260826
        let s = Schedule.make(preset: preset, seed: seed)
        if !recorder.isRecording { recorder.start() }
        recorder.writeSessionFiles(schedule: s, preset: preset.rawValue)
        runner.start(s)
    }

    @ViewBuilder private var phaseContent: some View {
        if studyMode {
            StudyView(runner: runner)
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
