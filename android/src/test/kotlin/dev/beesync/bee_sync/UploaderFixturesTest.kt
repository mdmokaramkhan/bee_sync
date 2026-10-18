package dev.beesync.bee_sync

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.ParameterizedRobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import kotlin.random.Random

/**
 * Runs spec/fixtures/uploader through the Android uploader, as
 * test/spec/uploader_fixtures_test.dart does for Dart.
 */
@RunWith(ParameterizedRobolectricTestRunner::class)
@Config(sdk = [34])
class UploaderFixturesTest(private val name: String, private val seed: Int) {

    companion object {
        @JvmStatic
        @ParameterizedRobolectricTestRunner.Parameters(name = "{0} seed={1}")
        fun cases(): List<Array<Any>> =
            File(specDir, "fixtures/uploader").listFiles { f -> f.name.endsWith(".json") }!!
                .map { it.nameWithoutExtension }
                .sorted()
                .flatMap { name -> listOf(0, 1, 2).map { arrayOf<Any>(name, it) } }
    }

    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var db: TestDb

    @Before fun setUp() {
        server = MockWebServer()
        db = TestDb(tmp.root)
    }

    @After fun tearDown() {
        db.close()
        server.shutdown()
    }

    @Test fun fixture() {
        val fixture = JSONObject(File(specDir, "fixtures/uploader/$name.json").readText())
        val now = fixture.getLong("now")

        val events = fixture.getJSONArray("events")
        for (i in 0 until events.length()) {
            val e = events.getJSONObject(i)
            val payload = if (e.has("payload_raw")) e.getString("payload_raw")
            else e.getJSONObject("properties").toString()
            db.insert(
                id = e.getString("id"),
                payload = payload.toByteArray(),
                name = e.getString("name"),
                priority = if (e.getString("priority") == "immediate") 1 else 0,
                createdAt = e.getLong("created_at"),
                attempts = e.getInt("attempts"),
                nextAttemptAt = e.getLong("next_attempt_at"),
                leaseOwner = e.optString("lease_owner").takeIf { !e.isNull("lease_owner") },
                leaseUntil = if (e.isNull("lease_until")) null else e.getLong("lease_until"),
            )
        }

        db.setMeta(MetaKeys.CONSENT, "granted")
        fixture.optJSONObject("meta")?.let { meta ->
            meta.keys().forEach { db.setMeta(it, meta.getString(it)) }
        }
        db.setMeta(
            MetaKeys.TRANSPORT_CONFIG,
            JSONObject()
                .put("endpoint", server.url("/events").toString())
                .put("headers", JSONObject())
                .put("gzip", false)
                .put("timeout_ms", 5000)
                .toString(),
        )
        fixture.optJSONObject("delivery_config")?.let {
            db.setMeta(MetaKeys.DELIVERY_CONFIG, it.toString())
        }

        val responses = fixture.getJSONArray("responses")
        val requests = mutableListOf<List<String>>()
        var unexpected: List<String>? = null
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val body = JSONObject(request.body.readUtf8())
                val ids = body.getJSONArray("events").let { a ->
                    (0 until a.length()).map { a.getJSONObject(it).getString("id") }
                }
                synchronized(requests) {
                    requests.add(ids)
                    if (requests.size > responses.length()) {
                        unexpected = ids
                        return MockResponse().setResponseCode(500)
                    }
                    val r = responses.getJSONObject(requests.size - 1)
                    if (r.optBoolean("network_error")) {
                        return MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)
                    }
                    return MockResponse().setResponseCode(r.getInt("status")).apply {
                        setBody(r.optString("body"))
                        r.optJSONObject("headers")?.let { h ->
                            h.keys().forEach { setHeader(it, h.getString(it)) }
                        }
                    }
                }
            }
        }

        val store = BeeSyncStore.open(db.path)!!
        val result = store.use {
            NativeUploader(it, UrlConnectionSender(), "test", clock = { now }, random = Random(seed))
                .run(
                    manual = fixture.optBoolean("manual", false),
                    networkAvailable = fixture.optBoolean("network_available", false),
                )
        }

        val expect = fixture.getJSONObject("expect")
        assertEquals("unexpected request", null, unexpected)
        assertEquals("status", expect.getString("status"), statusName(result.status))
        assertEquals("requests", toPlain(expect.getJSONArray("requests")), requests)

        val remaining = expect.getJSONArray("remaining")
        val rows = db.raw.rawQuery(
            "SELECT id, attempts, next_attempt_at, lease_owner FROM events ORDER BY seq",
            null,
        ).use { c ->
            buildList {
                while (c.moveToNext()) {
                    add(listOf(c.getString(0), c.getLong(1), c.getLong(2), c.getString(3)))
                }
            }
        }
        assertEquals(
            "remaining ids",
            (0 until remaining.length()).map { remaining.getJSONObject(it).getString("id") },
            rows.map { it[0] },
        )
        for ((i, row) in rows.withIndex()) {
            val exp = remaining.getJSONObject(i)
            assertTrue("${row[0]} still leased", (row[3] as String?)?.startsWith("android:") != true)
            if (exp.has("attempts")) assertEquals("${row[0]}.attempts", exp.getLong("attempts"), row[1])
            if (exp.has("next_attempt_at")) {
                assertValue("${row[0]}.next_attempt_at", exp.get("next_attempt_at"), row[2] as Long)
            }
        }

        val counters = BeeSyncStore.open(db.path)!!.use { it.counters() }.filterValues { it != 0L }
        val expectedCounters = expect.optJSONObject("counters")
            ?.let { c -> c.keys().asSequence().associateWith { c.getLong(it) } }
            ?: emptyMap()
        assertEquals("counters", expectedCounters, counters)

        expect.optJSONObject("meta")?.let { meta ->
            for (key in meta.keys()) {
                val actual = db.meta(key)
                if (key == MetaKeys.FLUSH_NOT_BEFORE) {
                    assertValue("meta.$key", meta.get(key), actual?.toLong() ?: 0L)
                } else {
                    assertEquals("meta.$key", meta.getString(key), actual)
                }
            }
        }
    }

    private fun statusName(s: RunStatus) = when (s) {
        RunStatus.DRAINED -> "drained"
        RunStatus.BACKING_OFF -> "backingOff"
        RunStatus.AUTH_BLOCKED -> "authBlocked"
        RunStatus.SKIPPED -> "skipped"
    }

    /** [expected] is a number (exact) or {"min","max"} (inclusive). */
    private fun assertValue(what: String, expected: Any, actual: Long) {
        if (expected is JSONObject) {
            val min = expected.getLong("min")
            val max = expected.getLong("max")
            assertTrue("$what = $actual not in [$min, $max]", actual in min..max)
        } else {
            assertEquals(what, (expected as Number).toLong(), actual)
        }
    }
}
