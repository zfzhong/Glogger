//
//  TouchLogger.swift
//  Passive, app-wide touch capture.
//
//  A UIGestureRecognizer attached to the key window sees every touch in the app.
//  With cancelsTouchesInView = false and a delegate that allows simultaneous
//  recognition, it observes touches WITHOUT consuming them — so the underlying
//  video / text field / board controls keep working while we log. This is the
//  iOS analog of the Android getevent stream, scoped to this app (the only scope
//  iOS permits without a jailbreak).
//
import SwiftUI
import UIKit

/// SwiftUI hook: drop `TouchLoggerView(recorder:)` into a `.background` so its
/// UIView joins the hierarchy and can reach the key window.
struct TouchLoggerView: UIViewRepresentable {
    let recorder: Recorder

    func makeUIView(context: Context) -> AttachView {
        let v = AttachView()
        v.recorder = recorder
        return v
    }
    func updateUIView(_ uiView: AttachView, context: Context) {}
}

final class AttachView: UIView {
    weak var recorder: Recorder?
    private var installed = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard !installed, let window = window, let rec = recorder else { return }
        let r = TouchRecognizer()
        r.logger = rec
        r.cancelsTouchesInView = false      // do not steal touches from controls
        r.delaysTouchesBegan = false
        r.delaysTouchesEnded = false
        r.delegate = r
        window.addGestureRecognizer(r)      // window retains it
        installed = true
    }
}

/// Never transitions state, so it never recognizes a "gesture" and never
/// interferes; it just forwards each UITouch to the Recorder.
final class TouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var logger: Recorder?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches, event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches, event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches, event) }

    /// The event is passed on, not dropped.
    ///
    /// UIKit delivers one UITouch per screen refresh, but the digitiser samples
    /// faster than that; the samples in between are reachable only through
    /// `event.coalescedTouches(for:)`. Throwing the event away cost us most of
    /// every stroke: session 0909_1215 wrote 3.6 KB of raw touch on the iPad
    /// against 17.4 KB on the Pixel for the same twenty scenes, and a swipe came
    /// out with path_len SHORTER than disp - impossible for a real finger, and a
    /// giveaway that four samples were being joined by straight lines.
    ///
    /// It biased the classifier's most fragile decision. Under-sampled path
    /// means under-measured mean_vel, which pushes an iPad swipe below flingVel
    /// and labels it scroll - the same movement that the Pixel calls a swipe.
    private func forward(_ touches: Set<UITouch>, _ event: UIEvent?) {
        guard logger?.isRecording == true else { return }
        for t in touches { logger?.ingest(t, event: event) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
