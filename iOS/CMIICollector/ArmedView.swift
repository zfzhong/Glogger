//
//  ArmedView.swift
//  The wait between arming a tablet and its scheduled start.
//
//  Two tablets have to begin on the same instant, and one pair of hands cannot
//  press two buttons simultaneously. So the button no longer waits for the
//  instant - it arms the tablet, and the instant is what starts the play. Before
//  this, disabling Start until the scheduled time meant the only possible
//  outcome was joining late, which is what the "not_run" rows were compensating
//  for.
//
//  The countdown runs on the SERVER clock, never this device's. Two tablets
//  counting down on their own clocks would still start as far apart as their
//  clocks are wrong, which restates the problem rather than solving it.
//
import SwiftUI

struct ArmedView: View {
    let play: Play
    let experimentName: String
    let remaining: TimeInterval
    let isRecording: Bool
    let clockKnown: Bool
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Circle().fill(isRecording ? .red : .gray).frame(width: 10, height: 10)
                Text(experimentName.isEmpty ? "Session" : experimentName).font(.headline)
                Text(isRecording ? "recording — waiting for the start"
                                 : "armed, waiting for the start")
                    .font(.callout).foregroundStyle(.secondary)
                if !clockKnown {
                    // Without a measured offset the countdown is only as good as
                    // this tablet's own clock, and two tablets can drift apart by
                    // more than a scene lasts.
                    Label("server clock not measured", systemImage: "clock.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                // Picking the wrong experiment on one of two tablets should not
                // need the app killed to undo.
                Button("Cancel", role: .cancel, action: onCancel)
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(.bar)
            Divider()

            ZStack {
                // The decks, so the participant knows where to look - but no cue.
                // Several seconds of "swipe left" on screen is several seconds of
                // rehearsal, and scene 1 stops being comparable to scene 8.
                StaticBoardView(play: play)
                    .opacity(0.18)
                    .allowsHitTesting(false)

                VStack(spacing: 12) {
                    Text("Starting in")
                        .font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    Text(clockText)
                        .font(.system(size: 84, weight: .light, design: .monospaced))
                        .monospacedDigit()
                    Text("Please hold still until the board lights up.")
                        .font(.title3).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 64).padding(.vertical, 36)
                .background(RoundedRectangle(cornerRadius: 28).fill(.quaternary))
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// m:ss, rounded up and floored at zero, so the last tick reads 0:00 rather
    /// than a negative.
    private var clockText: String {
        let total = max(0, Int(remaining.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The board with nothing happening on it: every deck face down, none live,
/// none touchable.
struct StaticBoardView: View {
    let play: Play

    var body: some View {
        let rows = max(1, play.rows), cols = max(1, play.cols)
        let gap: CGFloat = rows * cols > 9 ? 10 : 16
        let big = max(rows, cols)
        let side: CGFloat = big >= 4 ? 70 : (big == 3 ? 100 : 150)
        VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { c in
                        let b = r * cols + c
                        RoundedRectangle(cornerRadius: big >= 4 ? 14 : 22)
                            .fill(Color.gray.opacity(0.10))
                            .overlay(
                                CardFace(back: DeckBack.forBlock(b), faceUp: false,
                                         animal: "", cardSize: side))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}
