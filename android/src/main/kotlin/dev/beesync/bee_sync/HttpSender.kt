package dev.beesync.bee_sync

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.GZIPOutputStream

internal class HttpResponse(
    val status: Int,
    /** Lower-cased header names. */
    val headers: Map<String, String>,
    val body: String,
)

/** POSTs a request body; throws [IOException] for network failures. */
internal fun interface HttpSender {
    fun post(url: String, headers: Map<String, String>, body: ByteArray, timeoutMs: Int): HttpResponse
}

/** [HttpSender] on HttpURLConnection, so the plugin adds no HTTP dependency. */
internal class UrlConnectionSender : HttpSender {
    override fun post(
        url: String,
        headers: Map<String, String>,
        body: ByteArray,
        timeoutMs: Int,
    ): HttpResponse {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.useCaches = false
            conn.instanceFollowRedirects = false
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            for ((name, value) in headers) conn.setRequestProperty(name, value)
            conn.setFixedLengthStreamingMode(body.size)
            conn.outputStream.use { it.write(body) }

            val status = conn.responseCode
            val stream = if (status >= 400) conn.errorStream else conn.inputStream
            val text = stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            val responseHeaders = buildMap {
                for ((name, values) in conn.headerFields) {
                    if (name != null && values.isNotEmpty()) put(name.lowercase(), values.first())
                }
            }
            return HttpResponse(status, responseHeaders, text)
        } finally {
            conn.disconnect()
        }
    }
}

internal fun gzip(bytes: ByteArray): ByteArray {
    val out = ByteArrayOutputStream()
    GZIPOutputStream(out).use { it.write(bytes) }
    return out.toByteArray()
}
