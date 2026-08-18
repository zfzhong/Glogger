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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { forward(touches) }

    private func forward(_ touches: Set<UITouch>) {
        guard logger?.isRecording == true else { return }
        for t in touches { logger?.ingest(t) }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
