package com.cmii.collector

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView

/**
 * A pinned web page, used as a "free play" scene inside a play.
 *
 * Same reasoning as the iPad: an app can only observe touches delivered to its
 * own windows, so free use of a real site has to happen inside our own window to
 * be recorded at all. On Android the beacon would survive backgrounding, but the
 * touch record would not - and the touch record is the label.
 *
 * Android needs less machinery than iOS here. dispatchTouchEvent on the activity
 * already sees every touch over the WebView, so nothing special is required to
 * capture play inside an embedded game, including one in a cross-origin iframe.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebScene(
    url: String,
    onEvent: (String, String) -> Unit,
    modifier: Modifier = Modifier
) {
    val base = remember(url) { baseDomain(url) }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            // Nothing a participant does is kept between sessions: no cookies, no
            // local storage, no cache carried to the next person.
            CookieManager.getInstance().removeAllCookies(null)
            WebStorage.getInstance().deleteAllData()

            WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT)
                settings.apply {
                    javaScriptEnabled = true           // every browser game needs it
                    domStorageEnabled = true           // and its save state
                    mediaPlaybackRequiresUserGesture = false
                    loadWithOverviewMode = true
                    useWideViewPort = true
                    cacheMode = WebSettings.LOAD_NO_CACHE
                    // Ask for the mobile presentation the study is meant to
                    // imitate: tap-target size is part of what is being measured.
                    userAgentString = userAgentString.replace("; wv", "")
                }
                clearCache(true)
                isHorizontalScrollBarEnabled = false
                isVerticalScrollBarEnabled = false

                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(
                        view: WebView, request: WebResourceRequest
                    ): Boolean {
                        val target = request.url?.toString().orEmpty()
                        // Subresources and iframes never reach here; this is
                        // main-frame navigation only. A game embedded from another
                        // domain therefore loads normally, while a tap that would
                        // leave the site - an ad click - is cancelled and logged.
                        if (baseDomain(target) == base || target.startsWith("about:"))
                            return false
                        onEvent("blocked", target)
                        return true
                    }

                    override fun onPageStarted(v: WebView?, u: String?, f: Bitmap?) {
                        // nothing: the load event is what matters
                    }

                    override fun onPageFinished(v: WebView?, u: String?) {
                        onEvent("load", u.orEmpty())
                    }
                }

                // Browser games routinely ask for fullscreen; without a chrome
                // client the button silently does nothing, which reads as a broken
                // game rather than a disabled feature.
                webChromeClient = object : WebChromeClient() {}

                loadUrl(url)
            }
        },
        onRelease = { it.destroy() }
    )
}

/** Last two labels of the host, so m.poki.com is the same site and an ad network
 *  is not. */
fun baseDomain(url: String): String {
    val host = try { android.net.Uri.parse(url).host.orEmpty() } catch (_: Exception) { "" }
    val parts = host.split(".")
    return if (parts.size >= 2) parts.takeLast(2).joinToString(".") else host
}

/**
 * The approved list, as big plain tiles.
 *
 * Deliberately dull: this screen is not the task, and anything decorative here
 * would be gesture noise sitting in the middle of a free-play recording.
 */
@Composable
fun SiteMenu(prompt: String, sites: List<WebSite>, onPick: (WebSite) -> Unit) {
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        if (prompt.isNotBlank())
            Text(prompt, fontSize = 22.sp, textAlign = TextAlign.Center,
                 color = MaterialTheme.colorScheme.onSurfaceVariant,
                 modifier = Modifier.padding(top = 26.dp, bottom = 18.dp))
        LazyVerticalGrid(
            columns = GridCells.Adaptive(minSize = 240.dp),
            horizontalArrangement = Arrangement.spacedBy(18.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            contentPadding = PaddingValues(horizontal = 26.dp, vertical = 10.dp)
        ) {
            items(sites, key = { it.url }) { site ->
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    tonalElevation = 3.dp,
                    onClick = { onPick(site) },
                    modifier = Modifier.height(104.dp)
                ) {
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Text(site.label, fontSize = 20.sp, textAlign = TextAlign.Center)
                    }
                }
            }
        }
    }
}
