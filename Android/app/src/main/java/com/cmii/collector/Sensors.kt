package com.cmii.collector

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import androidx.core.content.ContextCompat

/**
 * Accelerometer, gyroscope and magnetometer at a fixed rate.
 *
 * SensorEvent.timestamp is nanoseconds since boot, which is the same clock and
 * the same origin as MotionEvent.eventTime - so on Android the touch stream and
 * the IMU stream share a time base natively. On iOS that had to be arranged.
 * Both are written as seconds since boot to match the iPad's columns.
 */
class MotionLogger(context: Context) : SensorEventListener {

    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private var recorder: Recorder? = null
    var nSamples = 0; private set

    /** 50 Hz, matching Slogger's watch-side accel and gyro rates so the two
     *  sides of a session are resampled the same way. */
    private val periodUs = 20_000

    fun start(rec: Recorder) {
        recorder = rec
        nSamples = 0
        listOf(Sensor.TYPE_ACCELEROMETER, Sensor.TYPE_GYROSCOPE, Sensor.TYPE_MAGNETIC_FIELD)
            .mapNotNull { sm.getDefaultSensor(it) }
            .forEach { sm.registerListener(this, it, periodUs) }
    }

    fun stop() {
        sm.unregisterListener(this)
        recorder = null
    }

    override fun onSensorChanged(e: SensorEvent) {
        val kind = when (e.sensor.type) {
            Sensor.TYPE_ACCELEROMETER -> "accel"
            Sensor.TYPE_GYROSCOPE -> "gyro"
            Sensor.TYPE_MAGNETIC_FIELD -> "mag"
            else -> return
        }
        nSamples++
        recorder?.writeImu(kind, e.timestamp, e.values[0], e.values[1], e.values[2])
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}

/**
 * Makes the tablet the beacon the watch scans for.
 *
 * Slogger filters on the exact device name, so the advertisement must carry it -
 * and on Android the name comes from the adapter, not from the advertise data,
 * so `includeDeviceName` is the switch that matters. Unlike iOS, this keeps
 * working when the app is backgrounded, which is why an Android tablet can be
 * the beacon during native-app sessions and an iPad cannot.
 */
class BleAdvertiser(private val context: Context) {

    private val adapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var callback: AdvertiseCallback? = null
    var lastError: String? = null; private set
    var advertising: Boolean = false; private set

    fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) ==
                PackageManager.PERMISSION_GRANTED

    /** Why the beacon is not running, in the operator's terms. A beacon that is
     *  silently off looks exactly like a watch that is not scanning. */
    fun readiness(): String? = when {
        adapter == null -> "this tablet has no Bluetooth adapter"
        !adapter.isEnabled -> "Bluetooth is off — turn it on in Settings"
        !hasPermission() -> "nearby-devices permission not granted"
        adapter.bluetoothLeAdvertiser == null -> "this tablet cannot advertise BLE"
        else -> null
    }

    fun start(name: String) {
        stop()
        readiness()?.let { lastError = it; return }
        val adv = adapter?.bluetoothLeAdvertiser ?: return
        try {
            @Suppress("MissingPermission")
            adapter.name = name          // the watch matches on this exact string
        } catch (_: SecurityException) { }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .setIncludeTxPowerLevel(true)
            .build()

        val cb = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
                advertising = true; lastError = null
            }
            override fun onStartFailure(errorCode: Int) {
                advertising = false
                lastError = when (errorCode) {
                    ADVERTISE_FAILED_DATA_TOO_LARGE -> "advertisement too large — name is too long"
                    ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "too many advertisers on this tablet"
                    ADVERTISE_FAILED_ALREADY_STARTED -> "already advertising"
                    ADVERTISE_FAILED_INTERNAL_ERROR -> "internal Bluetooth error"
                    ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "advertising not supported"
                    else -> "advertising failed ($errorCode)"
                }
            }
        }
        callback = cb
        try {
            @Suppress("MissingPermission")
            adv.startAdvertising(settings, data, cb)
        } catch (e: SecurityException) {
            lastError = "nearby-devices permission not granted"
        }
    }

    fun stop() {
        val cb = callback ?: return
        try {
            @Suppress("MissingPermission")
            adapter?.bluetoothLeAdvertiser?.stopAdvertising(cb)
        } catch (_: SecurityException) { }
        callback = null
        advertising = false
    }
}
