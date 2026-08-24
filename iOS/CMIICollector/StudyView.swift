//
//  StudyView.swift
//  The 2x2 cue screen. One block is live at a time; the other three stay visible
//  so the layout — and therefore the reach distances — remain constant.
//
import SwiftUI

struct StudyView: View {
    @ObservedObject var runner: TrialRunner

    var body: some View {
        VStack(spacing: 18) {
            header
            grid
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text(runner.phase == .idle ? "Not started"
                     : runner.phase == .done ? "Finished"
                     : "Trial \(min(runner.index + 1, runner.total)) of \(runner.total)")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(runner.nMatched)/\(runner.nDone) matched")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(runner.nDone),
                         total: Double(max(runner.total, 1)))

            Text(bannerText)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(bannerColor)
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentTransition(.identity)
                .animation(.easeOut(duration: 0.12), value: bannerText)
        }
    }

    private var bannerText: String {
        switch runner.phase {
        case .idle:  return "Press Start study"
        case .ready: return "Get ready…"
        case .cued, .settling:
            guard let t = runner.current else { return "" }
            return t.cueText
        case .gap:   return runner.lastOutcome
        case .done:  return "Done — \(runner.nMatched)/\(runner.nDone) matched"
        }
    }

    private var bannerColor: Color {
        switch runner.phase {
        case .cued, .settling: return .primary
        case .gap: return (runner.lastMatched == true) ? .green : .orange
        case .done: return .green
        default: return .secondary
        }
    }

    // MARK: Grid

    private var grid: some View {
        VStack(spacing: 16) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 16) {
                    ForEach(0..<2, id: \.self) { c in
                        cell(row: r, col: c)
                    }
                }
            }
        }
    }

    private func isLive(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .cued || runner.phase == .settling
        else { return false }
        return t.row == r && t.col == c
    }

    private func isFlashing(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .gap else { return false }
        return t.row == r && t.col == c
    }

    private func picture(_ r: Int, _ c: Int) -> String {
        let idx = r * 2 + c
        if let pics = runner.schedule?.blockPictures, idx < pics.count { return pics[idx] }
        // Before a schedule exists, still show four DIFFERENT animals so the idle
        // screen looks like the study rather than four identical placeholders.
        let fallback = Animals.all
        return fallback.isEmpty ? "pawprint.fill" : fallback[idx % fallback.count]
    }

    private func cell(row r: Int, col c: Int) -> some View {
        let live = isLive(r, c)
        let flashing = isFlashing(r, c)
        let matched = runner.lastMatched == true

        let fill: Color = flashing ? (matched ? .green.opacity(0.22) : .orange.opacity(0.22))
                                   : (live ? Color.accentColor.opacity(0.16)
                                           : Color.gray.opacity(0.10))
        let stroke: Color = flashing ? (matched ? .green : .orange)
                                     : (live ? .accentColor : .gray.opacity(0.25))

        return ZStack {
            RoundedRectangle(cornerRadius: 22).fill(fill)
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(stroke, lineWidth: live || flashing ? 6 : 2)

            VStack(spacing: 14) {
                Image(systemName: picture(r, c))
                    .resizable().scaledToFit()
                    .frame(maxWidth: 150, maxHeight: 150)
                    .foregroundStyle(live ? Color.accentColor : Color.secondary.opacity(0.55))
                    .scaleEffect(live ? 1.0 : 0.86)

                if live, let t = runner.current {
                    HStack(spacing: 10) {
                        Text(t.type.verb).font(.title2.weight(.semibold))
                        if let d = t.dir {
                            Image(systemName: d.arrow).font(.title2.weight(.bold))
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: live)
        .animation(.easeOut(duration: 0.15), value: flashing)
    }
}
