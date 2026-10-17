package dev.beesync.bee_sync

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import okio.GzipSource
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NativeUploaderTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var db: TestDb

    @Before fun setUp() {
        server = MockWebServer()
        db = TestDb(tmp.root)
        db.setMeta(MetaKeys.CONSENT, "granted")
    }

    @After fun tearDown() {
        db.close()
        server.shutdown()
    }

    private fun transport(gzip: Boolean = false, headers: Map<String, String> = emptyMap()) =
        db.setMeta(
            MetaKeys.TRANSPORT_CONFIG,
            JSONObject()
                .put("endpoint", server.url("/events").toString())
                .put("headers", JSONObject(headers))
                .put("gzip", gzip)
                .put("timeout_ms", 5000)
                .toString(),
        )

    private fun run(now: Long = 1_000L): RunResult = BeeSyncStore.open(db.path)!!.use {
        NativeUploader(it, UrlConnectionSender(), "android_worker", clock = { now }).run()
    }

    @Test fun wireFormatMatchesSpec() {
        val fixture = JSONObject(File(specDir, "fixtures/wire_format.json").readText())
        val events = fixture.getJSONArray("events")
        for (i in 0 until events.length()) {
            val e = events.getJSONObject(i)
            db.insert(
                id = e.getString("id"),
                payload = e.getString("payload").toByteArray(),
                name = e.getString("name"),
                priority = e.getInt("priority"),
                createdAt = e.getLong("created_at"),
                attempts = e.getInt("attempts"),
            )
        }
        transport(headers = mapOf("Authorization" to "Bearer t"))
        server.enqueue(MockResponse().setResponseCode(200))

        assertEquals(RunStatus.DRAINED, run(now = fixture.getLong("sent_at")).status)

        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("Bearer t", request.getHeader("Authorization"))
        assertEquals("application/json", request.getHeader("Content-Type"))
        val sdk = request.getHeader("X-BeeSync-Sdk")!!
        assertTrue(sdk, sdk.startsWith("bee_sync/") && sdk.endsWith("(android; android_worker)"))

        val body = JSONObject(request.body.readUtf8())
        assertEquals(request.getHeader("X-BeeSync-Batch-Id"), body.getString("batch_id"))
        assertTrue(body.getString("batch_id").matches(Regex("^[0-9a-f-]{36}$")))
        body.remove("batch_id")
        val expected = fixture.getJSONObject("expected_body").apply { remove("batch_id") }
        assertEquals(toPlain(expected), toPlain(body))
    }

    @Test fun gzipsWhenConfigured() {
        db.insert(id = "a", payload = """{"k":1}""".toByteArray())
        transport(gzip = true)
        server.enqueue(MockResponse().setResponseCode(200))

        run()

        val request = server.takeRequest()
        assertEquals("gzip", request.getHeader("Content-Encoding"))
        val json = Buffer().apply { writeAll(GzipSource(request.body)) }.readUtf8()
        assertEquals("a", JSONObject(json).getJSONArray("events").getJSONObject(0).getString("id"))
    }

    @Test fun skipsWithoutTransportConfig() {
        db.insert(id = "a", payload = "{}".toByteArray())
        val result = run()
        assertEquals(RunStatus.SKIPPED, result.status)
        assertEquals("transport", result.error)
        assertEquals(0, server.requestCount)
    }

    @Test fun parsesRetryAfter() {
        val now = 1_760_000_000_000L
        assertEquals(5_000L, NativeUploader.parseRetryAfter("5", now))
        assertEquals(120_000L, NativeUploader.parseRetryAfter("Thu, 09 Oct 2025 08:42:00 GMT", 1_759_999_200_000L))
        assertEquals(0L, NativeUploader.parseRetryAfter("Thu, 01 Jan 1970 00:00:00 GMT", now))
        assertNull(NativeUploader.parseRetryAfter("soon", now))
        assertNull(NativeUploader.parseRetryAfter("-3", now))
        assertNull(NativeUploader.parseRetryAfter(null, now))
    }

    @Test fun storeReportsSchemaVersion() {
        BeeSyncStore.open(db.path)!!.use { assertEquals(Sql.SCHEMA_VERSION, it.schemaVersion) }
        assertNull(BeeSyncStore.open(File(tmp.root, "missing.db").path))
    }
}
