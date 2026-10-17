package dev.beesync.bee_sync

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/** Keep in sync with `version` in pubspec.yaml. */
internal const val BEE_SYNC_VERSION = "0.2.0-dev"

internal object MetaKeys {
    const val CONSENT = "consent_state"
    const val TRANSPORT_CONFIG = "transport_config"
    const val DELIVERY_CONFIG = "delivery_config"
    const val FLUSH_NOT_BEFORE = "flush_not_before"
    const val AUTH_BLOCKED = "auth_blocked"
}

internal object CounterKeys {
    const val SENT = "sent"
    fun dropped(reason: String) = "dropped.$reason"
}

/** `meta.delivery_config`; missing keys use the contract defaults (§1.2). */
internal class DeliverySettings(
    val maxBatchSize: Int = 100,
    val maxBatchBytes: Int = 512 * 1024,
    val leaseMs: Long = 60_000,
    val retryBaseMs: Long = 2_000,
    val retryMaxMs: Long = 600_000,
    val maxAttempts: Int = 12,
) {
    companion object {
        fun parse(json: String?): DeliverySettings {
            val o = json?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject()
            val d = DeliverySettings()
            return DeliverySettings(
                maxBatchSize = o.optInt("max_batch_size", d.maxBatchSize),
                maxBatchBytes = o.optInt("max_batch_bytes", d.maxBatchBytes),
                leaseMs = o.optLong("lease_ms", d.leaseMs),
                retryBaseMs = o.optLong("retry_base_ms", d.retryBaseMs),
                retryMaxMs = o.optLong("retry_max_ms", d.retryMaxMs),
                maxAttempts = o.optInt("max_attempts", d.maxAttempts),
            )
        }
    }
}

/** `meta.transport_config` (§1.1). */
internal class TransportConfig(
    val endpoint: String,
    val headers: Map<String, String>,
    val gzip: Boolean,
    val timeoutMs: Int,
) {
    companion object {
        fun parse(json: String?): TransportConfig? {
            val o = json?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return null
            val endpoint = o.optString("endpoint").takeIf { it.isNotEmpty() } ?: return null
            val headers = o.optJSONObject("headers")
            return TransportConfig(
                endpoint = endpoint,
                headers = buildMap {
                    headers?.keys()?.forEach { put(it, headers.getString(it)) }
                },
                gzip = o.optBoolean("gzip", false),
                timeoutMs = o.optInt("timeout_ms", 30_000),
            )
        }
    }
}

internal enum class RunStatus { DRAINED, BACKING_OFF, AUTH_BLOCKED, SKIPPED }

internal class RunResult(
    val status: RunStatus,
    val delivered: Int = 0,
    val dropped: Int = 0,
    val retryAt: Long? = null,
    /** For SKIPPED: consent, transport, auth, backoff; otherwise the failure. */
    val error: String? = null,
)

/**
 * The native uploader: spec/uploader_contract.md §2–4, step for step. The Dart
 * reference is lib/src/core/flush_controller.dart; both run spec/fixtures.
 */
internal class NativeUploader(
    private val store: BeeSyncStore,
    private val sender: HttpSender,
    private val source: String,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: Random = Random.Default,
) {
    private val owner = "android:${UUID.randomUUID()}"
    private var dropped = 0

    /**
     * One run. Background runs are never [manual]; it exists so the shared
     * fixtures can run unchanged. [shouldContinue] is checked before each batch
     * (WorkManager may stop the worker).
     */
    fun run(manual: Boolean = false, shouldContinue: () -> Boolean = { true }): RunResult {
        if (store.getMeta(MetaKeys.CONSENT) != "granted") {
            return RunResult(RunStatus.SKIPPED, error = "consent")
        }
        val transport = TransportConfig.parse(store.getMeta(MetaKeys.TRANSPORT_CONFIG))
            ?: return RunResult(RunStatus.SKIPPED, error = "transport")
        val settings = DeliverySettings.parse(store.getMeta(MetaKeys.DELIVERY_CONFIG))
        val notBefore = store.getMeta(MetaKeys.FLUSH_NOT_BEFORE)?.toLongOrNull() ?: 0
        if (!manual) {
            if (store.getMeta(MetaKeys.AUTH_BLOCKED) == "1") {
                return RunResult(RunStatus.SKIPPED, error = "auth")
            }
            if (clock() < notBefore) {
                return RunResult(RunStatus.SKIPPED, retryAt = notBefore, error = "backoff")
            }
        }

        val result = Run(transport, settings).drain(shouldContinue)
        when (result.status) {
            RunStatus.DRAINED -> {
                if (notBefore != 0L) store.setMeta(MetaKeys.FLUSH_NOT_BEFORE, "0")
                if (manual) store.setMeta(MetaKeys.AUTH_BLOCKED, "0")
            }
            RunStatus.BACKING_OFF -> store.setMeta(MetaKeys.FLUSH_NOT_BEFORE, "${result.retryAt}")
            RunStatus.AUTH_BLOCKED -> store.setMeta(MetaKeys.AUTH_BLOCKED, "1")
            RunStatus.SKIPPED -> Unit
        }
        return result
    }

    private class Outcome(
        val delivered: Int = 0,
        val stop: RunStatus? = null,
        val retryAt: Long? = null,
        val error: String? = null,
    ) {
        fun plusDelivered(n: Int) = Outcome(delivered + n, stop, retryAt, error)
    }

    private sealed class SendResult {
        class Success(val rejected: Set<String>) : SendResult()
        class Retryable(val reason: String, val retryAfterMs: Long?) : SendResult()
        class Auth(val reason: String) : SendResult()
        object TooLarge : SendResult()
        class Permanent(val reason: String) : SendResult()
    }

    private inner class Run(val transport: TransportConfig, val settings: DeliverySettings) {

        fun drain(shouldContinue: () -> Boolean): RunResult {
            var delivered = 0
            while (shouldContinue()) {
                val now = clock()
                val claimed = store.claim(owner, now, now + settings.leaseMs, settings.maxBatchSize)
                if (claimed.isEmpty()) return RunResult(RunStatus.DRAINED, delivered, dropped)

                val batch = trimToBytes(claimed)
                if (batch.size < claimed.size) store.release(owner, claimed.drop(batch.size).map { it.id })

                val outcome = send(batch)
                delivered += outcome.delivered
                outcome.stop?.let {
                    return RunResult(it, delivered, dropped, outcome.retryAt, outcome.error)
                }
            }
            return RunResult(RunStatus.SKIPPED, delivered, dropped)
        }

        private fun trimToBytes(events: List<StoredEvent>): List<StoredEvent> {
            var bytes = 0L
            for ((i, e) in events.withIndex()) {
                bytes += e.sizeBytes
                // Always send at least one event, even if it alone exceeds the limit.
                if (i > 0 && bytes > settings.maxBatchBytes) return events.subList(0, i)
            }
            return events
        }

        private fun send(events: List<StoredEvent>): Outcome {
            val readable = ArrayList<Pair<StoredEvent, JSONObject>>()
            val unreadable = ArrayList<String>()
            for (e in events) {
                val properties = decode(e)
                if (properties == null) unreadable.add(e.id) else readable.add(e to properties)
            }
            if (unreadable.isNotEmpty()) drop(unreadable, "unreadable")
            if (readable.isEmpty()) return Outcome()
            val rows = readable.map { it.first }

            return when (val result = post(readable)) {
                is SendResult.Success -> {
                    val ids = rows.map { it.id }
                    val rejected = ids.filter { it in result.rejected }
                    val accepted = ids.size - rejected.size
                    store.deleteLeased(
                        owner,
                        ids,
                        mapOf(
                            CounterKeys.SENT to accepted,
                            CounterKeys.dropped("rejectedByServer") to rejected.size,
                        ),
                    )
                    dropped += rejected.size
                    Outcome(delivered = accepted)
                }
                is SendResult.Retryable -> retry(rows, result)
                is SendResult.Auth -> {
                    store.release(owner, rows.map { it.id })
                    Outcome(stop = RunStatus.AUTH_BLOCKED, error = result.reason)
                }
                SendResult.TooLarge -> splitOrDrop(rows, "tooLarge")
                is SendResult.Permanent -> splitOrDrop(rows, "rejectedByServer")
            }
        }

        private fun splitOrDrop(events: List<StoredEvent>, reason: String): Outcome {
            if (events.size == 1) {
                drop(listOf(events.single().id), reason)
                return Outcome()
            }
            val mid = events.size / 2
            val first = send(events.subList(0, mid))
            if (first.stop != null) {
                store.release(owner, events.drop(mid).map { it.id })
                return first
            }
            return send(events.subList(mid, events.size)).plusDelivered(first.delivered)
        }

        private fun retry(events: List<StoredEvent>, failure: SendResult.Retryable): Outcome {
            val now = clock()
            val exhausted = ArrayList<String>()
            val retry = ArrayList<String>()
            var maxAttempt = 1
            for (e in events) {
                val attempt = e.attempts + 1
                if (attempt >= settings.maxAttempts) {
                    exhausted.add(e.id)
                } else {
                    retry.add(e.id)
                    maxAttempt = max(maxAttempt, attempt)
                }
            }
            var delay = backoffDelay(maxAttempt)
            failure.retryAfterMs?.let { if (it > delay) delay = it }
            val retryAt = now + delay

            if (exhausted.isNotEmpty()) drop(exhausted, "maxAttempts")
            store.releaseRetry(owner, retry, retryAt)
            return Outcome(stop = RunStatus.BACKING_OFF, retryAt = retryAt, error = failure.reason)
        }

        /** §3.1: equal jitter in [cap/2, cap]. */
        private fun backoffDelay(attempt: Int): Long {
            val exp = (attempt - 1).coerceIn(0, 30)
            val cap = min(settings.retryMaxMs, settings.retryBaseMs * (1L shl exp))
            val half = cap / 2
            return half + random.nextLong(cap - half + 1)
        }

        private fun drop(ids: List<String>, reason: String) {
            store.deleteLeased(owner, ids, mapOf(CounterKeys.dropped(reason) to ids.size))
            dropped += ids.size
        }

        private fun post(events: List<Pair<StoredEvent, JSONObject>>): SendResult {
            val batchId = UUID.randomUUID().toString()
            val body = JSONObject()
                .put("batch_id", batchId)
                .put("sent_at", clock())
                .put(
                    "events",
                    JSONArray().apply {
                        for ((e, properties) in events) {
                            put(
                                JSONObject()
                                    .put("id", e.id)
                                    .put("name", e.name)
                                    .put("timestamp", e.createdAt)
                                    .put("priority", if (e.priority == 1) "immediate" else "normal")
                                    .put("attempt", e.attempts + 1)
                                    .put("properties", properties),
                            )
                        }
                    },
                )
            var bytes = body.toString().toByteArray(Charsets.UTF_8)
            val headers = LinkedHashMap(transport.headers)
            headers["Content-Type"] = "application/json"
            headers["X-BeeSync-Batch-Id"] = batchId
            headers["X-BeeSync-Sdk"] = "bee_sync/$BEE_SYNC_VERSION (android; $source)"
            if (transport.gzip) {
                bytes = gzip(bytes)
                headers["Content-Encoding"] = "gzip"
            }

            val response = try {
                sender.post(transport.endpoint, headers, bytes, transport.timeoutMs)
            } catch (e: Exception) {
                // IOException (offline, timeout, TLS) and malformed endpoints alike.
                return SendResult.Retryable("Network error: ${e.javaClass.simpleName}", null)
            }
            return classify(response, clock())
        }
    }

    private fun decode(e: StoredEvent): JSONObject? {
        if (e.encrypted) return null // Encryption arrives in v0.3.
        return try {
            JSONObject(e.payload.toString(Charsets.UTF_8))
        } catch (_: JSONException) {
            null
        }
    }

    private fun classify(response: HttpResponse, now: Long): SendResult {
        val status = response.status
        val reason = "HTTP $status"
        return when {
            status in 200..299 -> SendResult.Success(rejectedIds(response.body))
            status == 401 || status == 403 -> SendResult.Auth(reason)
            status == 413 -> SendResult.TooLarge
            status == 408 || status == 429 || status >= 500 ->
                SendResult.Retryable(reason, parseRetryAfter(response.headers["retry-after"], now))
            status >= 400 -> SendResult.Permanent(reason)
            else -> SendResult.Retryable("Unexpected $reason", null) // 1xx/3xx
        }
    }

    private fun rejectedIds(body: String): Set<String> = try {
        val rejected = JSONObject(body).optJSONArray("rejected") ?: JSONArray()
        buildSet {
            for (i in 0 until rejected.length()) {
                (rejected.opt(i) as? String)?.let { add(it) }
            }
        }
    } catch (_: JSONException) {
        emptySet()
    }

    companion object {
        /** `Retry-After`: delay-seconds or an HTTP-date. Null when absent or invalid. */
        fun parseRetryAfter(value: String?, now: Long): Long? {
            if (value == null) return null
            value.trim().toLongOrNull()?.let { return if (it < 0) null else it * 1000 }
            return try {
                val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US)
                format.timeZone = TimeZone.getTimeZone("GMT")
                max(0L, format.parse(value.trim())!!.time - now)
            } catch (_: ParseException) {
                null
            }
        }
    }
}
