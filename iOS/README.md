# CMIICollector — iPad data collector

iPad counterpart of the Android `adb`/`getevent` collector in [`../tools`](../tools).
Because iOS is sandboxed (no `getevent`, no `logcat`, no `adb`), collection happens
**inside this app**: the three study phases run as screens, and a passive window
gesture recognizer logs every touch without consuming it. CoreBluetooth logs the
watch's advertised RSSI, replacing Slogger's role.

## Why in-app (and not idb / a system-wide tool)

iOS gives no passive stream of a real user's touches on other apps. `adb`-style
bridges (incl. **facebook/idb**) only **inject** input or take AX/screen snapshots —
they cannot read the taps a person makes. Per-tap ground truth is therefore only
available (without a jailbreak) for touches **inside your own app**. The upside:
we also get contact `majorRadius`, which `getevent` never provided.

> **`force` is always 0 for finger input on this iPad.** The 12.9" 6th gen has no
> finger force sensing — `UITouch.force` is non-zero only for Apple Pencil.
> Verified across all 513 touch samples of session `0824_1043`. The column is kept
> for schema stability and for Pencil sessions; do not treat it as a feature.
> `majorRadius` does work (0–31.3 pt observed).

## Output (per session, in the app's Documents/sessions/<name>/)

| file | schema | notes |
|---|---|---|
| `<name>_taps.csv` | `tablet_wall_ms,kernel_ts,x,y` | one row per touch-down — **matches the Android taps.csv** |
| `<name>_gestures.csv` | `wall_ms,kernel_down,kernel_up,type,n_fingers,x0,y0,x1,y1,dur_ms,disp,path_len,mean_vel,max_vel` | **byte-compatible** with the offline pipeline; classifier ported from `tools/gesture_parse.py` |
| `<name>_touches_raw.csv` | `wall_ms,kernel_ts,touch_id,phase,x,y,force,major_radius,study_phase` | full stream — the source-of-truth analog to `getevent.log` |
| `<name>_ble.csv` | `wall_ms,name,uuid,rssi` | one row per received advertisement |

`kernel_ts` is `UITouch.timestamp` (seconds since boot, monotonic) — the iOS analog
of the getevent kernel clock. `wall_ms` is Unix epoch ms, for alignment with the
Pixel Watch exactly as today.

## Build & run

Requires Xcode. Open `CMIICollector.xcodeproj` and run on an iPad (real device for
BLE + force; the simulator works for touches/CSV but has no Bluetooth).

Command line:

```bash
xcodebuild -project CMIICollector.xcodeproj -scheme CMIICollector \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' build
```

For a physical iPad, set your signing team in the target (Automatic signing) and
build to the device; grant the Bluetooth permission prompt on first Start.

## Operator flow

1. Enter a **Session name** and a **BLE name filter** (substring of the watch's
   advertised name; blank = log all peripherals).
2. **Start** → run the three phases via the segmented control: **Browse**
   (scroll+tap), **Type** (keyboard), **Tap grid** (discrete taps).
3. **Stop** → **Export** (share sheet: AirDrop / Files / Save to Files).

## Calibration

Gesture thresholds live in `GestureThresholds` (GestureClassifier.swift) and are in
**points** / points-per-second (getevent used raw device units). Defaults:
`moveDist 10`, `flingVel 600`, `longPressMs 500`, `pinchDelta 20`, `rotateDeg 15`.
Re-run a labeled session and adjust as needed; because `touches_raw.csv` is kept,
gestures can also be re-derived offline without recollecting.

## Not captured (vs Android)

- **Which third-party app is foreground / PiP** — impossible for other apps on iOS
  (Screen Time's `DeviceActivity` gives only coarse usage, no coordinates). Not
  needed here since all three phases run inside this app.
