# Glogger — GestureLogger

One tablet app, built twice: **iOS/** in Swift and SwiftUI, **Android/** in Kotlin
and Compose. Both ship as *GestureLogger*, with the same icon and the same four
screens.

They are a pair on purpose. Two tablets running two halves of one study have to
present the same board and keep the same timeline, so a difference between the
platforms is a bug rather than a variation.

```
Android/    com.cmii.collector   — Kotlin, Compose, minSdk 30
iOS/        com.cmii.collector   — Swift, SwiftUI, iPadOS 17+
```

## What the app does

It records what a participant does on a tablet, against a study timeline it
downloads from a server:

- every touch at digitiser resolution, including the batched history samples
- gestures classified on device, and — separately — what the board itself did,
  which is ground truth the classifier cannot supply
- motion at 50 Hz, and BLE, either advertising a beacon for a wrist-worn watch
  to measure or scanning for one
- one row per scene, whether or not this tablet was the one playing it

Scenes are held to fixed slots measured from a scheduled instant, so two tablets
begin together and stay in step with no link between them. Measured across
twenty scenes on an iPad and a Pixel: no drift, 43 ms of spread.

## Building

**Android** — `cd Android && ./gradlew assembleDebug`, then
`adb install -r app/build/outputs/apk/debug/app-debug.apk`.

**iOS** — open `iOS/CMIICollector.xcodeproj`, pick a device, run. Signing needs
an Apple ID in Xcode's Accounts settings; the command line cannot reach it.

The Xcode target and project are still named `CMIICollector` — the app's display
name is what changed to GestureLogger, and renaming the target would churn the
project file for nothing.

## The server

The app is not useful alone. It needs the collection server, which holds the
gesture book, the plays, the device register and the schedule, and which
receives the uploads. That lives in the **CMII-BLE** repository alongside the
analysis code and the recordings.

A tablet registers itself on first launch and appears there unnamed. Naming it
and assigning it to an experiment is what makes any experiment visible on it.

## History

These folders were `ipad/` and `android/` inside CMII-BLE until they were split
out here, with their history intact — `git log` and `git blame` still explain
why things are the way they are.
