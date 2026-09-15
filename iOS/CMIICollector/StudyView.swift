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
    /// (event, detail) from a web scene - "load", "blocked", "fail" - so the
    /// recorder can write a timeline of what was actually on screen.
    var onWebEvent: ((String, String) -> Void)? = nil

    /// One deck per block. Reset whenever the scene changes, so the board a
    /// participant sees on trial 20 is identical to the one on trial 2 - otherwise
    /// flicked-down decks accumulate and the visual scene drifts through a session.
    @State private var decks: [Int: DeckState] = [:]
    /// Cell frames in the grid's coordinate space, so a carried card can be drawn
    /// above every block and the drop target resolved from where it was released.
    @State private var frames: [Int: CGRect] = [:]
    @State private var carry: (block: Int, offset: CGSize)?

    /// A card that has been thrown and is still leaving. Held apart from the
    /// deck state because the deck must not lose the card until the animation
    /// showing it go has finished, or the next card appears underneath the one
    /// still in the air.
    @State private var flung: (block: Int, animal: String, at: CGPoint, dir: CGSize)?
    @State private var flight: CGFloat = 0
    /// Which page a menu-style web scene is currently showing. Nil = the menu.
    @State private var picked: WebSite?

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
        Group {
            if let t = webScene {
                webBody(t)
            } else {
                boardBody
            }
        }
        .onChange(of: runner.index) { _, _ in decks = [:]; carry = nil; picked = nil }
        .onChange(of: runner.phase) { _, p in
            if p == .idle { decks = [:] }
            // A drag needs the participant to know WHICH card is being moved,
            // so the card to be dragged is turned face up as the cue appears.
            //
            // Only a travelling scene. On a tap scene the card has to start
            // face down or there is nothing to flip, and the flip is the
            // gesture being measured.
            //
            // At the cue, not at the start of the scene: a face showing during
            // "Get ready" would name the target a second early, and the
            // participant would have their hand there before the scene began.
            if p == .cued, let t = runner.current, t.revealsCard {
                let b = t.row * grid.cols + t.col
                var st = decks[b] ?? DeckState()
                // The plain half-turn: this reveal is the app showing the card,
                // not feedback on a gesture, so it should not look like one.
                st.reveal = .flip
                st.faceUp = true
                decks[b] = st
            }
        }
    }

    private var boardBody: some View {
        // A waiting slot and an off-screen scene both dim the board and put text
        // over it; they differ only in what the text says and why.
        let quiet = offscreenScene ?? waitingScene
        return VStack(spacing: 18) {
            header
            ZStack {
                gridView
                    .opacity(quiet == nil ? 1 : 0.18)
                    .allowsHitTesting(quiet == nil)
                    .animation(.easeInOut(duration: 0.25), value: quiet == nil)
                if let t = offscreenScene {
                    offscreenPrompt(t)
                } else if let t = waitingScene {
                    waitingPrompt(t)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The other tablet is playing. Deliberately plain and unhurried: nothing to
    /// do here, and anything that looked interactive would pull the participant's
    /// attention to the wrong screen.
    @ViewBuilder private func waitingPrompt(_ t: Trial) -> some View {
        VStack(spacing: 14) {
            // The counter is repeated here, not just left in the header: an empty
            // slot IS a scene, and this panel is the only thing being read while
            // it runs. Without it the run looks stalled rather than under way.
            Text("Scene \(min(runner.index + 1, runner.total)) of \(runner.total)"
                 + "  ·  \((runner.remainingMs + 999) / 1000)s")
                .font(.title3.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
            Text(t.promptText.isEmpty ? "Please read the other Device" : t.promptText)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 52).padding(.vertical, 30)
        .frame(maxWidth: 760)
        .background(RoundedRectangle(cornerRadius: 24).fill(.quaternary))
        .transition(.opacity)
    }

    /// A web scene takes the whole screen apart from a thin operator strip. The
    /// participant should be using the site, not reading study chrome - but the
    /// operator still needs to see which scene is running and how far in it is.
    @ViewBuilder private func webBody(_ t: Trial) -> some View {
        // A single-page scene goes straight to the page; a menu scene starts on
        // the menu and comes back to it whenever the participant asks.
        let live: URL? = picked?.link ?? (t.siteList.isEmpty ? t.webURL : nil)
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if !t.siteList.isEmpty, picked != nil {
                    Button {
                        picked = nil
                        onWebEvent?("menu", "")
                    } label: {
                        Label("Games", systemImage: "square.grid.2x2")
                    }
                    .font(.footnote)
                }
                Text("Scene \(min(runner.index + 1, runner.total)) of \(runner.total)")
                if let p = picked {
                    Text(p.label).lineLimit(1)
                } else if !t.promptText.isEmpty {
                    Text(t.promptText).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 12)
                ProgressView(value: Double(runner.nDone),
                             total: Double(max(runner.total, 1)))
                    .frame(width: 150)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(.bar)

            if let url = live {
                // Keyed on the page so switching games reloads rather than
                // continuing where the previous one left off.
                WebScene(url: url, onEvent: onWebEvent)
                    .id("\(t.i)-\(url.absoluteString)")
            } else {
                siteMenu(t)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
    }

    /// The approved list, as big plain tiles. Deliberately dull: this screen is
    /// not the task, and anything decorative here would be gesture noise sitting
    /// in the middle of a free-play recording.
    @ViewBuilder private func siteMenu(_ t: Trial) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                if !t.promptText.isEmpty {
                    Text(t.promptText)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 26)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 18)],
                          spacing: 18) {
                    ForEach(t.siteList) { site in
                        Button {
                            picked = site
                            onWebEvent?("pick", site.url)
                        } label: {
                            Text(site.label)
                                .font(.title3.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 96)
                                .background(RoundedRectangle(cornerRadius: 14)
                                                .fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Text(runner.phase == .idle ? "Not started"
                     : runner.phase == .done ? "Finished"
                     : "Scene \(min(runner.index + 1, runner.total)) of \(runner.total)")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                // Seconds left in the SLOT, not in the cue window. The scene ends
                // when this reaches zero and not before, so the number and the
                // scene counter always agree - finishing the gesture early no
                // longer skips the board forward.
                //
                // Still no verdict here. A participant told they got it wrong
                // performs the next gesture differently.
                if runner.isRunning {
                    Text("\((runner.remainingMs + 999) / 1000)s")
                        .font(.title3.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(runner.nDone),
                         total: Double(max(runner.total, 1)))

            Text(offscreenScene == nil && waitingScene == nil ? bannerText : "")
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
        case .gap:   return ""
        case .done:  return "All done — thank you"
        }
    }

    private var bannerColor: Color {
        switch runner.phase {
        case .cued, .settling: return .primary
        case .gap: return .secondary
        case .done: return .green
        default: return .secondary
        }
    }

    /// What the participant reads when the scene is away from the tablet.
    @ViewBuilder private func offscreenPrompt(_ t: Trial) -> some View {
        VStack(spacing: 22) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text(t.promptText)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineSpacing(6)
                .frame(maxWidth: 760)
        }
        .padding(44)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(.background)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(.secondary.opacity(0.25), lineWidth: 1))
        .transition(.opacity)
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
        .overlay(alignment: .topLeading) { flungCard }
    }

    /// The card under the finger. Drawn here rather than in its cell so it can
    /// pass over the other blocks instead of being clipped by them.
    /// The thrown card, on its way out along the direction it was thrown.
    @ViewBuilder private var flungCard: some View {
        if let g = flung {
            let big = max(rows, cols)
            let side: CGFloat = big >= 4 ? 70 : (big == 3 ? 100 : 150)
            // Far enough to be gone rather than stopping at the screen edge.
            let reach: CGFloat = 760
            CardFace(back: DeckBack.forBlock(g.block), faceUp: true,
                     animal: g.animal, cardSize: side, lifted: true)
                .frame(width: side, height: side * 1.35)
                .position(x: g.at.x + g.dir.width * reach * flight,
                          y: g.at.y + g.dir.height * reach * flight)
                .opacity(1 - flight)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var carriedCard: some View {
        if let carry, let f = frames[carry.block] {
            let st = decks[carry.block] ?? DeckState()
            let side = min(f.width * 0.66, f.height / 1.35 * 0.82)
            CardFace(back: DeckBack.forBlock(carry.block),
                     // Face up the instant it lifts, and without a flip
                     // animation: a card in the hand is a card you can see.
                     faceUp: true,
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
            // Lands face up. Until it did, a drop that worked and a drop that
            // missed left the board looking exactly the same.
            dst.reveal = .flip
            dst.faceUp = true
            decks[target] = dst
            runner.cardDropped(from: src, to: target, animal: animal)
        } else if hypot(predicted.width, predicted.height) > 120 {
            // Thrown, but not onto anything: a flick discards the top card. It
            // leaves along the direction it was thrown rather than blinking out
            // of existence, so the throw has a visible consequence.
            // The card leaves along the CUED direction - the way the arrow on
            // screen points - not along the exact angle the finger took. The
            // arrow and the card then agree, and the animation is the same
            // every time rather than being at the mercy of a hand's wobble.
            // `predicted` still decides WHETHER it was a throw.
            let cued = runner.current?.dir
            let v: CGSize = {
                switch cued {
                case "L": return CGSize(width: -1, height: 0)
                case "R": return CGSize(width: 1, height: 0)
                case "U": return CGSize(width: 0, height: -1)   // y grows downward
                case "D": return CGSize(width: 0, height: 1)
                default:
                    // No direction in the cue: fall back to where the hand went.
                    return hypot(translation.width, translation.height) > 1
                        ? translation : predicted
                }
            }()
            let len = max(1, hypot(v.width, v.height))
            flung = (src, animal,
                     CGPoint(x: f.midX + translation.width, y: f.midY + translation.height),
                     CGSize(width: v.width / len, height: v.height / len))
            flight = 0
            // The row is written at the release, so the timing in the file is
            // the gesture's and not the animation's.
            runner.cardDropped(from: src, to: nil, animal: animal)
            withAnimation(.easeIn(duration: 0.30)) { flight = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                guard let g = flung else { return }
                var s2 = decks[g.block] ?? DeckState()
                if s2.discarded < deckAnimals(g.block).count - 1 {
                    s2.discarded += 1
                    s2.faceUp = false
                    decks[g.block] = s2
                }
                flung = nil
            }
        }
    }

    private func isLive(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .cued || runner.phase == .settling
        else { return false }
        // An off-screen scene still carries a row and column from the generator,
        // but lighting a deck would contradict the prompt telling the participant
        // to leave the tablet alone.
        if t.isFreeform { return false }
        return t.row == r && t.col == c
    }

    /// GAP is part of the scene, not a pause between scenes.
    ///
    /// The runner leaves the cue window and sits in .gap until the slot ends.
    /// That used to be invisible, because the scene advanced a moment later. Now
    /// that the slot is what advances it, a screen keyed on the earlier phases
    /// blanked itself for the last seconds of its own scene.
    private var webScene: Trial? {
        guard let t = runner.current, t.isWeb,
              runner.phase == .ready || runner.phase == .cued
                || runner.phase == .settling || runner.phase == .gap else { return nil }
        return t
    }

    /// GAP is part of the scene, not a pause between scenes.
    ///
    /// The runner leaves the cue window and sits in .gap until the slot ends.
    /// That used to be invisible, because the scene advanced a moment later. Now
    /// that the slot is what advances it, a screen keyed on the earlier phases
    /// blanked itself for the last seconds of its own scene.
    private var waitingScene: Trial? {
        guard let t = runner.current, t.isWaiting,
              runner.phase == .ready || runner.phase == .cued
                || runner.phase == .settling || runner.phase == .gap else { return nil }
        return t
    }

    /// GAP is part of the scene, not a pause between scenes.
    ///
    /// The runner leaves the cue window and sits in .gap until the slot ends.
    /// That used to be invisible, because the scene advanced a moment later. Now
    /// that the slot is what advances it, a screen keyed on the earlier phases
    /// blanked itself for the last seconds of its own scene.
    private var offscreenScene: Trial? {
        guard let t = runner.current, t.isOffscreen,
              runner.phase == .ready || runner.phase == .cued
                || runner.phase == .settling || runner.phase == .gap else { return nil }
        return t
    }

    /// Where a travelling gesture has to end up. Drawn as a distinct target so
    /// drag length is set by the layout rather than by how far the participant
    /// felt like going.
    private func isDestination(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, t.isTravelling,
              runner.phase == .cued || runner.phase == .settling else { return false }
        return t.toRow == r && t.toCol == c
    }

    /// Which edge of the cell the direction arrow sits against.
    private func directionCorner(_ t: Trial?) -> Alignment {
        guard let d = t?.dir, t?.revealsCard == true else { return .center }
        // The card is nearly as tall as the cell but much narrower, so there is
        // room either side of it and almost none above or below. An up arrow at
        // .top lands behind the card and is simply not seen; kept in the side
        // margin it stays clear, and its height in the cell still says which way.
        switch d {
        case "L": return .leading
        case "R": return .trailing
        case "U": return .topTrailing
        default:  return .bottomTrailing
        }
    }

    private func isFlashing(_ r: Int, _ c: Int) -> Bool {
        guard let t = runner.current, runner.phase == .gap else { return false }
        // The flash acknowledges a scene that was acted on. A waiting or
        // water-break scene has nothing to acknowledge, and its row and column
        // are carried over from the tablet that IS playing - the flash would
        // light a block chosen by the other tablet.
        if t.isWaiting || t.isOffscreen { return false }
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
        // Neutral flash: acknowledges the block that was acted on without saying
        // whether it was right.
        let flashTint: Color = .secondary

        let fill: Color = flashing ? flashTint.opacity(0.18)
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
                        // The deck keeps the card until the flight ends, so
                        // the next card does not appear early - but it must not
                        // DRAW it, or there are two copies and the one sitting
                        // still reads as the card snapping back to the deck.
                        carrying: carry?.block == b || flung?.block == b,
                        state: Binding(
                            get: { decks[b] ?? DeckState() },
                            set: { decks[b] = $0 }),
                        onEvent: { e in
                            runner.deckRow(block: b, event: e.rawValue,
                                           animal: topAnimal(of: b, state: decks[b] ?? DeckState()))
                        },
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
        // The cue names a direction in words; this puts it on the board. The
        // arrow sits against the edge the card is meant to travel toward, so
        // the participant does not have to map "right" onto the layout while
        // the clock runs. Only where the direction is part of the task: a drag
        // or a flick moves the card somewhere, a tap does not.
        .overlay(alignment: directionCorner(live ? runner.current : nil)) {
            if live, let t = runner.current, t.revealsCard, let d = t.dir,
               let glyph = ["L": "←", "R": "→", "U": "↑", "D": "↓"][d] {
                Text(glyph)
                    .font(.system(size: big >= 4 ? 34 : (big == 3 ? 46 : 64),
                                  weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: live)
        .animation(.easeOut(duration: 0.15), value: flashing)
    }
}
