//
//  StudyView.swift
//  The cue screen. One block is live at a time; the rest stay visible so the
//  layout — and therefore the reach distances — remain constant.
//
//  The grid is whatever the play says (rows x cols), not a fixed 2x2. The
//  server can emit other layouts, and a hardcoded 2x2 would silently drop every
//  trial addressed to row or column 2: no cell would light up, the participant
//  would see nothing to do, and the trial would time out looking like a miss.
//
import SwiftUI

struct StudyView: View {
    @ObservedObject var runner: TrialRunner

    /// One deck per block. Reset whenever the scene changes, so the board a
    /// participant sees on trial 20 is identical to the one on trial 2 - otherwise
    /// flicked-down decks accumulate and the visual scene drifts through a session.
    @State private var decks: [Int: DeckState] = [:]
    /// Cell frames in the grid's coordinate space, so a carried card can be drawn
    /// above every block and the drop target resolved from where it was released.
    @State private var frames: [Int: CGRect] = [:]
    @State private var carry: (block: Int, offset: CGSize)?

    /// Grid shape comes from the SCENE, falling back to the play default.
    ///
    /// It is read from `runner.displayTrial` rather than `runner.current` so the
    /// grid does not collapse to the default during the gap between scenes - the
    /// screen would visibly reflow between every trial.
    private var grid: (rows: Int, cols: Int) {
        guard let s = runner.play else { return (2, 2) }
        guard let t = runner.displayTrial else { return (max(1, s.rows), max(1, s.cols)) }
        return t.grid(default: s)
    }
    private var rows: Int { grid.rows }
    private var cols: Int { grid.cols }

    var body: some View {
        VStack(spacing: 18) {
            header
            gridView
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: runner.index) { _, _ in decks = [:]; carry = nil }
        .onChange(of: runner.phase) { _, p in if p == .idle { decks = [:] } }
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
        // Three states: matched, missed, and not verifiable. An unscored gesture
        // must not be painted like a failure - nothing went wrong.
        case .gap:
            switch runner.lastMatched {
            case .some(true): return .green
            case .some(false): return .orange
            case nil: return .secondary
            }
        case .done: return .green
        default: return .secondary
        }
    }

    // MARK: Grid

    private var gridView: some View {
        let gap: CGFloat = rows * cols > 9 ? 10 : 16
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { c in
                        cell(row: r, col: c)
                    }
                }
            }
        }
        .coordinateSpace(name: "grid")
        .onPreferenceChange(CellFrameKey.self) { frames = $0 }
        .overlay(alignment: .topLeading) { carriedCard }
    }

    /// The card under the finger. Drawn here rather than in its cell so it can
    /// pass over the other blocks instead of being clipped by them.
    @ViewBuilder private var carriedCard: some View {
        if let carry, let f = frames[carry.block] {
            let st = decks[carry.block] ?? DeckState()
            let side = min(f.width * 0.66, f.height / 1.35 * 0.82)
            CardFace(back: DeckBack.forBlock(carry.block),
                     faceUp: st.showsFace,
                     animal: topAnimal(of: carry.block, state: st),
                     cardSize: max(40, side), lifted: true)
                .frame(width: max(40, side), height: max(40, side) * 1.35)
                .position(x: f.midX + carry.offset.width,
                          y: f.midY + carry.offset.height)
                .shadow(color: .black.opacity(0.32), radius: 16, x: 0, y: 10)
                .allowsHitTesting(false)
        }
    }

    private func topAnimal(of block: Int, state st: DeckState) -> String {
        if let last = st.received.last { return last }
        let a = deckAnimals(block)
        return a[min(st.discarded, a.count - 1)]
    }

    /// Which block a release landed in, in grid coordinates.
    private func blockAt(_ p: CGPoint) -> Int? {
        frames.first { $0.value.contains(p) }?.key
    }

    private func endCarry(from src: Int, translation: CGSize, predicted: CGSize) {
        defer { carry = nil }
        guard let f = frames[src] else { return }
        let end = CGPoint(x: f.midX + translation.width, y: f.midY + translation.height)
        var st = decks[src] ?? DeckState()
        let animal = topAnimal(of: src, state: st)

        if let target = blockAt(end), target != src {
            // Landed on another block: the card moves there.
            st.discarded = min(st.discarded + 1, max(0, deckAnimals(src).count - 1))
            st.faceUp = false
            decks[src] = st
            var dst = decks[target] ?? DeckState()
            dst.received.append(animal)
            decks[target] = dst
            runner.cardDropped(from: src, to: target)
        } else if hypot(predicted.width, predicted.height) > 120 {
            // Thrown, but not onto anything: a flick discards the top card.
            if st.discarded < deckAnimals(src).count - 1 {
                st.discarded += 1
                st.faceUp = false
                decks[src] = st
            }
            runner.cardDropped(from: src, to: nil)
        }
    }

    private func isLive(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .cued || runner.phase == .settling
        else { return false }
        return t.row == r && t.col == c
    }

    /// Where a travelling gesture has to end up. Drawn as a distinct target so
    /// drag length is set by the layout rather than by how far the participant
    /// felt like going.
    private func isDestination(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, t.isTravelling,
              runner.phase == .cued || runner.phase == .settling else { return false }
        return t.toRow == r && t.toCol == c
    }

    private func isFlashing(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .gap else { return false }
        return t.row == r && t.col == c
    }

    /// The three faces in one deck. Different animals within a deck, and the deck
    /// is identified by its back rather than by these, so repeats across decks
    /// are fine - there are only 11 symbols in the pool.
    private func deckAnimals(_ block: Int) -> [String] {
        let pool = runner.play?.blockPictures ?? Animals.all
        guard !pool.isEmpty else { return ["pawprint.fill"] }
        return (0..<3).map { pool[(block * 3 + $0) % pool.count] }
    }

    private func picture(_ r: Int, _ c: Int) -> String {
        let idx = r * cols + c
        if let pics = runner.play?.blockPictures, idx < pics.count { return pics[idx] }
        // Before a play exists, still show four DIFFERENT animals so the idle
        // screen looks like the study rather than four identical placeholders.
        let fallback = Animals.all
        return fallback.isEmpty ? "pawprint.fill" : fallback[idx % fallback.count]
    }

    private func cell(row r: Int, col c: Int) -> some View {
        let live = isLive(r, c)
        let dest = isDestination(r, c)
        let flashing = isFlashing(r, c)
        let verdict = runner.lastMatched            // nil = not verifiable
        let flashTint: Color = verdict == nil ? .secondary : (verdict! ? .green : .orange)

        let fill: Color = flashing ? flashTint.opacity(0.22)
                                   : (live ? Color.accentColor.opacity(0.16)
                                     : (dest ? Color.green.opacity(0.12)
                                             : Color.gray.opacity(0.10)))
        let stroke: Color = flashing ? flashTint
                                     : (live ? .accentColor
                                        : (dest ? .green : .gray.opacity(0.25)))

        // Shrink the furniture as the grid grows, so a 3x3 or 4x4 still fits.
        let big = max(rows, cols)
        let radius: CGFloat = big >= 4 ? 14 : (big == 3 ? 18 : 22)
        let art: CGFloat = big >= 4 ? 70 : (big == 3 ? 100 : 150)
        let pad: CGFloat = big >= 4 ? 8 : (big == 3 ? 12 : 18)

        return ZStack {
            RoundedRectangle(cornerRadius: radius).fill(fill)
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(stroke, style: StrokeStyle(
                    lineWidth: live || flashing ? 6 : (dest ? 5 : 2),
                    dash: dest ? [10, 7] : []))

            VStack(spacing: big >= 4 ? 6 : 14) {
                // Sized off the cell, not a fixed constant: the deck IS the block
                // content, so it should fill it rather than float in the middle.
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    let side = min(w * 0.66, h / 1.35 * 0.82)
                    let b = r * cols + c
                    CardDeckView(
                        block: b,
                        animals: deckAnimals(b),
                        live: live,
                        interactive: live,
                        cardSize: max(40, side),
                        carrying: carry?.block == b,
                        state: Binding(
                            get: { decks[b] ?? DeckState() },
                            set: { decks[b] = $0 }),
                        onDragChanged: { off in carry = (b, off) },
                        onDragEnded: { tr, pred in
                            endCarry(from: b, translation: tr, predicted: pred)
                        })
                        .frame(width: w, height: h)
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: CellFrameKey.self,
                                value: [b: g.frame(in: .named("grid"))])
                        })
                }
                    .scaleEffect(live ? 1.0 : 0.94)
                    .opacity(dest ? 0.55 : 1)      // the drop target, not the thing to grab

                if dest, let t = runner.current, let icon = t.directionIcon {
                    HStack(spacing: 6) {
                        Image(systemName: icon)
                        Text("drop here")
                    }
                    .font(big >= 4 ? .caption : .headline)
                    .foregroundStyle(.green)
                }

                if live, let t = runner.current {
                    HStack(spacing: big >= 4 ? 5 : 10) {
                        Text(t.displayVerb)
                            .font(big >= 4 ? .headline : .title2.weight(.semibold))
                            .minimumScaleFactor(0.6).lineLimit(1)
                        if let icon = t.directionIcon {
                            Image(systemName: icon)
                                .font(big >= 4 ? .headline : .title2.weight(.bold))
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(pad)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: live)
        .animation(.easeOut(duration: 0.15), value: flashing)
    }
}
