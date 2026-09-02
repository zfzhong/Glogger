package com.cmii.collector

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Posts a session's files to the collection server, one multipart request each.
 *
 * The shape follows sloggerlib's HttpController, with one deliberate omission:
 * that class carries an insecureTls path with a trust-all X509TrustManager for a
 * legacy host. The collector only ever talks to a server with a valid
 * certificate, so that code has no reason to exist here.
 *
 * The queue continues past a failure rather than stopping at it. A single file
 * the server rejects should not strand the twenty behind it - that is how a
 * whole session gets left on a tablet because one CSV had an unexpected name.
 */
class Uploader {

    private val http = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .writeTimeout(120, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    suspend fun upload(
        files: List<File>,
        session: String,
        base: String,
        study: String,
        participant: String,
        token: String?,
        experimentId: Int,
        onProgress: (String) -> Unit
    ): String = withContext(Dispatchers.IO) {
        if (files.isEmpty()) return@withContext "nothing to upload"
        val url = base.trim().trimEnd('/') + "/cmii/upload/"
        var sent = 0
        var failed = 0
        files.forEachIndexed { i, f ->
            onProgress("uploading ${i + 1}/${files.size} — ${f.name}")
            try {
                val body = MultipartBody.Builder().setType(MultipartBody.FORM)
                    .addFormDataPart("file", f.name,
                        f.asRequestBody("text/csv".toMediaTypeOrNull()))
                    .addFormDataPart("session", session)
                    .addFormDataPart("platform", "android")
                    .addFormDataPart("study", study)
                    .addFormDataPart("participant", participant)
                    .apply {
                        if (experimentId > 0)
                            addFormDataPart("experiment", experimentId.toString())
                        if (!token.isNullOrBlank()) addFormDataPart("token", token)
                    }
                    .build()
                val req = Request.Builder().url(url).post(body).build()
                http.newCall(req).execute().use { resp ->
                    if (resp.isSuccessful) sent++ else failed++
                }
            } catch (_: Exception) {
                failed++
            }
        }
        val msg = if (failed == 0) "uploaded $sent files"
                  else "uploaded $sent, FAILED $failed"
        onProgress(msg)
        msg
    }
}
