//
//  CardDeck.swift
//  A block is a deck of animal cards.
//
//  Every gesture in the vocabulary acts on this one object, which is why it exists:
//  the alternative was a zoomable image for pinch, a rotatable one for rotate and a
//  scrollable strip for scroll - three components instead of one.
//
//  It also gives ground truth that does not depend on the classifier. A card
//  visibly flipping is independent evidence the tap landed, which is exactly what
//  pinch IN vs OUT and rotate CW vs CCW cannot get from stroke geometry.
//
//  See CARD_DECK_DESIGN.md.
//
import SwiftUI

// MARK: - Identity

/// Colour plus texture, one pairing per deck, stable for a session.
///
/// Colour is what survives the cell shrinking - artwork drops to 100pt at 3x3 and
/// 70pt at 4x4, where a fine pattern on its own turns to grey mush.
enum DeckTexture: Int, CaseIterable {
    case stripes, dots, grid, chevrons, rings, waves
}

struct DeckBack {
    var hue: Double
    var texture: DeckTexture

    var color: Color { Color(hue: hue, saturation: 0.55, brightness: 0.78) }
    var deep: Color { Color(hue: hue, saturation: 0.65, brightness: 0.55) }

    /// Deterministic from the block index, so a deck looks the same all session.
    static func forBlock(_ i: Int) -> DeckBack {
        let hues: [Double] = [0.02, 0.09, 0.14, 0.33, 0.52, 0.58, 0.72, 0.85, 0.95]
        return DeckBack(hue: hues[i % hues.count],
                        texture: DeckTexture.allCases[i % DeckTexture.allCases.count])
    }
}

/// The pattern drawn over a card back. Kept coarse on purpose: fine detail is
/// invisible once a 4x4 cell shrinks the card.
private struct TexturePattern: View {
    let texture: DeckTexture
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let step = max(10.0, min(w, h) / 5.0)
            Canvas { ctx, size in
                var p = Path()
                switch texture {
                case .stripes:
                    var x = -h
                    while x < w { p.move(to: CGPoint(x: x, y: 0))
                                  p.addLine(to: CGPoint(x: x + h, y: h)); x += step }
                case .grid:
                    var x = step / 2
                    while x < w { p.move(to: CGPoint(x: x, y: 0))
                                  p.addLine(to: CGPoint(x: x, y: h)); x += step }
                    var y = step / 2
                    while y < h { p.move(to: CGPoint(x: 0, y: y))
                                  p.addLine(to: CGPoint(x: w, y: y)); y += step }
                case .chevrons:
                    var y = -step
                    while y < h + step {
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w / 2, y: y + step / 2))
                        p.addLine(to: CGPoint(x: w, y: y))
                        y += step
                    }
                case .waves:
                    var y = step / 2
                    while y < h {
                        p.move(to: CGPoint(x: 0, y: y))
                        var x: CGFloat = 0
                        while x < w {
                            p.addQuadCurve(to: CGPoint(x: x + step, y: y),
                                           control: CGPoint(x: x + step / 2,
                                                            y: y - step / 2))
                            x += step
                        }
                        y += step
                    }
                case .dots:
                    var y = step / 2
                    while y < h {
                        var x = step / 2
                        while x < w {
                            p.addEllipse(in: CGRect(x: x - step / 6, y: y - step / 6,
                                                    width: step / 3, height: step / 3))
                            x += step
                        }
                        y += step
                    }
                case .rings:
                    var r = step / 2
                    while r < max(w, h) {
                        p.addEllipse(in: CGRect(x: w / 2 - r, y: h / 2 - r,
                                                width: r * 2, height: r * 2))
                        r += step / 1.5
                    }
                }
                if texture == .dots {
                    ctx.fill(p, with: .color(tint))
                } else {
                    ctx.stroke(p, with: .color(tint), lineWidth: max(1.5, step / 8))
                }
            }
            .frame(width: w, height: h)
        }
    }
}

// MARK: - State

/// Reset at the start of every scene. Without that the board drifts: a deck that
/// has been flicked twice looks nothing like a fresh one, and trial 20 stops being
/// comparable to trial 2.
struct DeckState: Equatable {
    var discarded = 0          // cards flicked away, revealing the one beneath
    var faceUp = false         // top card flipped
    var peeking = false        // held down: face shown until release

    var showsFace: Bool { faceUp || peeking }
}

/// What the deck actually did, independent of what the classifier decided.
enum DeckEvent: String {
    case flip, unflip, peek, peekEnd, discard
}

// MARK: - View

struct CardDeckView: View {
    let block: Int
    let animals: [String]
    let live: Bool
    let cardSize: CGFloat
    @Binding var state: DeckState
    var onEvent: (DeckEvent) -> Void = { _ in }

    private var back: DeckBack { DeckBack.forBlock(block) }
    private var depth: Int { max(1, animals.count - state.discarded) }
    private var topAnimal: String {
        animals.isEmpty ? "pawprint.fill" : animals[min(state.discarded, animals.count - 1)]
    }

    var body: some View {
        ZStack {
            // Cards beneath, peeking out so the stack reads as a stack.
            ForEach(0..<max(0, depth - 1), id: \.self) { i in
                cardShape(faceUp: false, animal: "")
                    .offset(x: CGFloat(depth - 1 - i) * 3.5,
                            y: CGFloat(depth - 1 - i) * 3.5)
                    .opacity(0.9)
            }
            cardShape(faceUp: state.showsFace, animal: topAnimal)
                .rotation3DEffect(.degrees(state.showsFace ? 180 : 0),
                                  axis: (x: 0, y: 1, z: 0))
                .animation(.easeInOut(duration: 0.22), value: state.showsFace)
                .gesture(flick)
                .onTapGesture(count: 2) { set(.unflip) }        // must precede single
                .onTapGesture { set(.flip) }
                .onLongPressGesture(minimumDuration: 0.35, pressing: { down in
                    state.peeking = down
                    onEvent(down ? .peek : .peekEnd)
                }, perform: {})
        }
        .frame(width: cardSize, height: cardSize * 1.35)
        .animation(.easeOut(duration: 0.18), value: state.discarded)
    }

    /// A flick discards the top card. Judged on predicted end translation rather
    /// than distance travelled, which is what separates a flick from a slow drag.
    private var flick: some Gesture {
        DragGesture(minimumDistance: 18)
            .onEnded { v in
                let pred = hypot(v.predictedEndTranslation.width,
                                 v.predictedEndTranslation.height)
                if pred > 120, state.discarded < animals.count - 1 {
                    state.discarded += 1
                    state.faceUp = false
                    onEvent(.discard)
                }
            }
    }

    private func set(_ e: DeckEvent) {
        switch e {
        case .flip:   guard !state.faceUp else { return }; state.faceUp = true
        case .unflip: guard state.faceUp else { return }; state.faceUp = false
        default: return
        }
        onEvent(e)
    }

    @ViewBuilder
    private func cardShape(faceUp: Bool, animal: String) -> some View {
        let r = cardSize * 0.11
        ZStack {
            RoundedRectangle(cornerRadius: r)
                .fill(faceUp ? Color(white: 0.99) : back.color)
            if !faceUp {
                TexturePattern(texture: back.texture, tint: back.deep.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: r))
            } else if !animal.isEmpty {
                Image(systemName: animal)
                    .resizable().scaledToFit()
                    .padding(cardSize * 0.18)
                    .foregroundStyle(back.deep)
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            RoundedRectangle(cornerRadius: r)
                .strokeBorder(faceUp ? back.deep.opacity(0.5) : Color.black.opacity(0.18),
                              lineWidth: 2)
        }
        .shadow(color: .black.opacity(live ? 0.22 : 0.12),
                radius: live ? 6 : 3, x: 0, y: 2)
    }
}
