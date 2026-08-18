//
//  CMIICollectorApp.swift
//  In-app data collector for the CMII-BLE tablet-user-identification study.
//
//  iPad counterpart of the Android adb/getevent collector. Because iOS is
//  sandboxed (no getevent/logcat), collection happens *inside* this app: the
//  three study phases run as screens here, and a passive window gesture
//  recognizer logs every touch without consuming it. CoreBluetooth logs the
//  watch's advertised RSSI, replacing Slogger's role.
//
import SwiftUI

@main
struct CMIICollectorApp: App {
    @StateObject private var recorder = Recorder()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(recorder)
        }
    }
}
