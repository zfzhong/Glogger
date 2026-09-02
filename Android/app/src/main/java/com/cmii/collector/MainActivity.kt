package com.cmii.collector

import android.os.Bundle
import android.view.MotionEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * The Android side of the collector.
 *
 * Touch capture is the one place Android is plainly better than iOS: an activity
 * sees every touch delivered anywhere in the app through dispatchTouchEvent,
 * including touches over a WebView, with pressure and size already on the event.
 * No gesture recognizer attached to the window, no cancelsTouchesInView, and
 * nothing that can steal a touch from the view underneath - the event is passed
 * straight on afterwards.
 */
class MainActivity : ComponentActivity() {

    private var touchCount by mutableStateOf(0)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Column(
                        modifier = Modifier.fillMaxSize().padding(24.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text("CMII Collector", style = MaterialTheme.typography.headlineMedium)
                        Spacer(Modifier.height(12.dp))
                        Text("touch events seen: $touchCount",
                             style = MaterialTheme.typography.bodyLarge)
                    }
                }
            }
        }
    }

    /** Observes, never consumes: the event is always passed on to the view tree. */
    override fun dispatchTouchEvent(ev: MotionEvent): Boolean {
        touchCount += ev.historySize + 1
        return super.dispatchTouchEvent(ev)
    }
}
