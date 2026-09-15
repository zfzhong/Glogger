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

/// How the face arrives. The gesture that revealed the card chooses this, so the
/// animation is feedback about what the participant actually did: a slow spin
/// means "that was read as a tap", a snap means "double tap", a spreading circle
/// means "hold".
///
/// Cosmetic only. Nothing downstream reads it - the classifier's verdict and the
/// deck event are both written at the moment of the gesture, before any of this
/// has finished playing.
enum RevealStyle {
    case flip     // the plain half-turn: drag and flick scenes, and anything else
    case spin     // tap: one and a half turns, slow enough to watch
    case fast     // double tap: the same half-turn, snapped
    case circle   // hold: no rotation, the face spreads from the centre
}

/// Reset at the start of every scene. Without that the board drifts: a deck that
/// has been flicked twice looks nothing like a fresh one, and trial 20 stops being
/// comparable to trial 2.
struct DeckState: Equatable {
    var discarded = 0          // cards flicked away, revealing the one beneath
    var faceUp = false         // top card flipped
    var peeking = false        // held down: face shown until release
    var received: [String] = []  // cards dragged onto this deck from elsewhere
    var reveal: RevealStyle = .flip

    var showsFace: Bool { faceUp || peeking }
}

/// Tap's spin. David asked for a full second; this is shorter on purpose.
///
/// A tap scene and a double-tap scene look identical, so a participant unsure
/// whether the first tap registered taps again - and if the card is still
/// turning a second later, that second tap lands inside the double-tap window
/// and the trial is recorded as the wrong gesture. Settling before the window is
/// comfortably closed removes the reason to tap twice.
private let spinSeconds  = 0.60
private let fastSeconds  = 0.12
private let flipSeconds  = 0.22
private let irisSeconds  = 0.42

/// What the deck actually did, independent of what the classifier decided.
enum DeckEvent: String {
    case flip, unflip, peek, peekEnd, discard, pickUp, dropped, dropMissed
}

/// Cell frames in the grid's coordinate space, so a dragged card can be drawn
/// above every block and the drop target worked out from where it was released.
/// A card dragged inside its own cell would be clipped by the neighbouring block.
struct CellFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, b in b }
    }
}

// MARK: - View

struct CardDeckView: View {
    let block: Int
    let animals: [String]
    let live: Bool
    /// Only the cued deck responds. A non-target deck that flipped when tapped
    /// would reward tapping the wrong one, and the point of the cue is that the
    /// participant goes to the right block. Off-target taps are still recorded -
    /// TouchLogger sits on the window, so the data is kept even though the card
    /// does nothing.
    let interactive: Bool
    let cardSize: CGFloat
    /// Identity of the card on top: which card, in which scene. When it changes
    /// the turn and the circle start over instead of animating.
    ///
    /// Without it the source block of a successful drag played a flip: the card
    /// had been face up to be dragged, the drop set the deck face down again,
    /// and the animation read as the card turning back over - contradicting the
    /// fact that it had just gone to another block. Nothing is turning over
    /// there. The card left, and a different card, which was always face down,
    /// is now on top.
    let cardKey: Int
    /// True while this deck's top card is being carried; the card is drawn by the
    /// grid overlay instead, so the original is hidden rather than duplicated.
    var carrying: Bool = false
    @Binding var state: DeckState
    var onEvent: (DeckEvent) -> Void = { _ in }
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: (CGSize, CGSize) -> Void = { _, _ in }

    private var back: DeckBack { DeckBack.forBlock(block) }
    private var depth: Int { max(1, animals.count - state.discarded) + state.received.count }
    var topAnimal: String {
        if let last = state.received.last { return last }
        return animals.isEmpty ? "pawprint.fill"
                               : animals[min(state.discarded, animals.count - 1)]
    }

    var body: some View {
        ZStack {
            // Cards beneath, peeking out so the stack reads as a stack.
            ForEach(0..<max(0, depth - 1), id: \.self) { i in
                CardFace(back: back, faceUp: false, animal: "",
                         cardSize: cardSize, lifted: live)
                    .offset(x: CGFloat(depth - 1 - i) * 3.5,
                            y: CGFloat(depth - 1 - i) * 3.5)
                    .opacity(0.9)
            }
            // The flip rotation goes on the card; the gestures go on an
            // untransformed wrapper around it.
            //
            // Sharing one view inverted the drag on Android, where pointer
            // positions are mapped back through the layer's transform: at 180
            // degrees about y the layer is mirrored, so a finger moving left
            // reported deltas moving right. It stayed hidden while cards were
            // face down during a gesture, and appeared the moment drag and
            // flick scenes started revealing the card. The same shape is not
            // worth keeping here on the chance SwiftUI differs.
            ZStack {
                TurningCard(angle: turn, back: back, animal: topAnimal,
                            cardSize: cardSize, lifted: live)
                    .animation(.easeInOut(duration: turnSeconds), value: turn)
                    .opacity(carrying ? 0 : 1)
                    .id(cardKey)

                // Hold's reveal: the face laid over the back, masked to a circle
                // that grows from the centre. A second card rather than a mask on
                // the first, because the first is the one the rotation and the
                // carry-alpha act on and this one must do neither.
                //
                // Always present, closed to nothing when it is not wanted, so
                // that opening and closing both animate - an overlay inserted by
                // an `if` would appear already open.
                CardFace(back: back, faceUp: true, animal: topAnimal,
                         cardSize: cardSize, lifted: live)
                    .mask(Circle()
                            .frame(width: irisFull, height: irisFull)
                            .scaleEffect(irisOpen ? 1 : 0.0001))
                    .opacity(carrying ? 0 : 1)
                    .animation(.easeOut(duration: irisSeconds), value: irisOpen)
                    .allowsHitTesting(false)
                    .id(cardKey)
            }
            .contentShape(Rectangle())
            .allowsHitTesting(interactive)
            .gesture(drag)
            .onTapGesture(count: 2) { doubleTapped() }      // must precede single
            .onTapGesture { tapped() }
            .onLongPressGesture(minimumDuration: 0.35, pressing: { down in
                if down { state.reveal = .circle }
                state.peeking = down
                onEvent(down ? .peek : .peekEnd)
            }, perform: {})
        }
        .frame(width: cardSize, height: cardSize * 1.35)
        .animation(.easeOut(duration: 0.18), value: state.discarded)
    }

    /// One gesture serves both flick and drag - they start identically. Where it
    /// ends up decides: released over another block it is a drop, otherwise a
    /// fast throw is a flick. The grid owns that decision because only it knows
    /// where the other blocks are.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in onDragChanged(v.translation) }
            .onEnded { v in onDragEnded(v.translation, v.predictedEndTranslation) }
    }



    // MARK: Reveal

    /// How far the card turns. `circle` does not turn at all - it stays face
    /// down and the face spreads over it.
    private var turn: Double {
        guard state.showsFace else { return 0 }
        switch state.reveal {
        case .circle: return 0
        case .spin:   return 540      // a turn and a half
        default:      return 180
        }
    }

    private var turnSeconds: Double {
        switch state.reveal {
        case .spin: return spinSeconds
        case .fast: return fastSeconds
        default:    return flipSeconds
        }
    }

    private var irisOpen: Bool { state.reveal == .circle && state.showsFace }

    /// The diameter that covers the card: the diagonal, not the width. A circle
    /// reaching only the long edges would leave the four corners permanently
    /// hidden, and the hold is meant to end with the whole card visible.
    private var irisFull: CGFloat { hypot(cardSize, cardSize * 1.35) }

    private func tapped() {
        guard !state.faceUp else { return }
        state.reveal = .spin
        state.faceUp = true
        onEvent(.flip)
    }

    private func doubleTapped() {
        state.reveal = .fast
        if state.faceUp {
            state.faceUp = false
            onEvent(.unflip)
        } else {
            // On a double-tap scene the card starts face down, so the second tap
            // has to reveal it - otherwise the cued gesture is the one gesture on
            // the board that does nothing.
            state.faceUp = true
            onEvent(.flip)
        }
    }
}

/// The card mid-turn.
///
/// Animatable so the face can be chosen from the angle actually on screen rather
/// than from the destination: rotating past 90 degrees shows the layer mirrored,
/// and with a spin passing 90, 270 and 450 there are three such crossings. A
/// view that simply swapped the face when the gesture landed would show the
/// animal reversed for a third of the spin, and would give it away at once.
private struct TurningCard: View, Animatable {
    var angle: Double
    let back: DeckBack
    let animal: String
    let cardSize: CGFloat
    let lifted: Bool

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showing = cos(angle * .pi / 180) < 0
        CardFace(back: back, faceUp: showing, animal: animal,
                 cardSize: cardSize, lifted: lifted, counterRotate: showing)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0))
    }
}

/// One card. Standalone so the grid can draw a floating copy under the finger -
/// a card dragged inside its own cell would be clipped by the next block.
struct CardFace: View {
    let back: DeckBack
    let faceUp: Bool
    let animal: String
    let cardSize: CGFloat
    var lifted: Bool = false
    /// Set when this card is drawn inside a parent turned an odd half-turn about
    /// y, where everything comes out mirrored. Only the artwork needs undoing -
    /// the back's texture and the border are symmetric enough not to show it.
    ///
    /// It used to be unconditional, which was right for the deck's own card and
    /// wrong for every standalone copy: the card flying away from a flick and the
    /// one carried under the finger are not inside a rotated parent, so they were
    /// drawing their animals back to front.
    var counterRotate: Bool = false

    var body: some View {
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
                    .rotation3DEffect(.degrees(counterRotate ? 180 : 0),
                                      axis: (x: 0, y: 1, z: 0))
            }
            RoundedRectangle(cornerRadius: r)
                .strokeBorder(faceUp ? back.deep.opacity(0.5) : Color.black.opacity(0.18),
                              lineWidth: 2)
        }
        .shadow(color: .black.opacity(lifted ? 0.22 : 0.12),
                radius: lifted ? 6 : 3, x: 0, y: 2)
    }
}
