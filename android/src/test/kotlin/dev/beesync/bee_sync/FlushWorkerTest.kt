package dev.beesync.bee_sync

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.TestWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executors

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FlushWorkerTest {
    @get:Rule val tmp = TemporaryFolder()
    private val context: Context = ApplicationProvider.getApplicationContext()
    private lateinit var server: MockWebServer
    private lateinit var db: TestDb

    @Before fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setMinimumLoggingLevel(Log.DEBUG).setExecutor(SynchronousExecutor()).build(),
        )
        server = MockWebServer()
        db = TestDb(tmp.root)
        db.setMeta(MetaKeys.CONSENT, "granted")
        db.setMeta(
            MetaKeys.TRANSPORT_CONFIG,
            JSONObject()
                .put("endpoint", server.url("/events").toString())
                .put("headers", JSONObject())
                .put("gzip", false)
                .put("timeout_ms", 5000)
                .toString(),
        )
        configure(enabled = true)
    }

    @After fun tearDown() {
        db.close()
        server.shutdown()
    }

    private fun configure(enabled: Boolean) {
        context.getSharedPreferences(BeeSyncPlugin.PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(BeeSyncPlugin.KEY_DATABASE_PATH, db.path)
            .putBoolean(BeeSyncPlugin.KEY_ENABLED, enabled)
            .commit()
    }

    private fun runWorker(): ListenableWorker.Result =
        TestWorkerBuilder.from(context, FlushWorker::class.java, Executors.newSingleThreadExecutor())
            .build()
            .doWork()

    private fun logLines(): List<String> =
        db.raw.rawQuery(Sql.SELECT_BG_LOG, arrayOf("10")).use { c ->
            buildList { while (c.moveToNext()) add("${c.getString(1)}/${c.getString(2)}: ${c.getString(3)}") }
        }

    private fun state(name: String): WorkInfo.State? =
        WorkManager.getInstance(context).getWorkInfosForUniqueWork(name).get().firstOrNull()?.state

    private fun eventCount(): Long =
        db.raw.rawQuery(Sql.COUNT_EVENTS, null).use { it.moveToFirst(); it.getLong(0) }

    @Test fun deliversQueuedEventsAndLogsTheRun() {
        db.insert(id = "a", payload = "{}".toByteArray())
        db.insert(id = "b", payload = "{}".toByteArray())
        server.enqueue(MockResponse().setResponseCode(200))

        assertEquals(ListenableWorker.Result.success(), runWorker())

        assertEquals(1, server.requestCount)
        assertEquals(0L, eventCount())
        assertEquals(listOf("android_worker/info: drained: sent 2, dropped 0"), logLines())
    }

    @Test fun drainingCancelsThePeriodicJob() {
        BackgroundWork.schedule(context)
        db.insert(id = "a", payload = "{}".toByteArray())
        server.enqueue(MockResponse().setResponseCode(200))

        runWorker()

        assertEquals(WorkInfo.State.CANCELLED, state(BackgroundWork.PERIODIC))
    }

    @Test fun backoffSchedulesADelayedRetry() {
        db.insert(id = "a", payload = "{}".toByteArray())
        server.enqueue(MockResponse().setResponseCode(503))

        runWorker()

        assertEquals(WorkInfo.State.ENQUEUED, state(BackgroundWork.RETRY))
        assertEquals(1L, eventCount())
        assertTrue(db.meta(MetaKeys.FLUSH_NOT_BEFORE)!!.toLong() > System.currentTimeMillis())
        assertTrue(logLines().single(), logLines().single().startsWith("android_worker/warn: backing_off"))
    }

    @Test fun skippingForAnActiveBackoffSchedulesARetry() {
        // The app's own flush failed moments ago and set the global backoff.
        db.setMeta(MetaKeys.FLUSH_NOT_BEFORE, "${System.currentTimeMillis() + 30_000}")
        db.insert(id = "a", payload = "{}".toByteArray())

        runWorker()

        assertEquals(0, server.requestCount)
        assertEquals(WorkInfo.State.ENQUEUED, state(BackgroundWork.RETRY))
    }

    @Test fun aBackoffFromNetworkFailuresEndsWhenTheWorkerRuns() {
        // Queued offline: the app's failed uploads left a long network backoff.
        // The job only runs with a network connection, so the outage is over.
        val later = System.currentTimeMillis() + 5 * 60_000
        db.setMeta(MetaKeys.NETWORK_FAILURES, "8")
        db.setMeta(MetaKeys.FLUSH_NOT_BEFORE, "$later")
        db.insert(id = "a", payload = "{}".toByteArray(), nextAttemptAt = later)
        server.enqueue(MockResponse().setResponseCode(200))

        runWorker()

        assertEquals(1, server.requestCount)
        assertEquals(0L, eventCount())
        assertEquals("0", db.meta(MetaKeys.NETWORK_FAILURES))
    }

    @Test fun eventsLeasedByTheAppAreRetriedWhenTheLeaseExpires() {
        // The app was killed mid-request: its lease still hides the event.
        db.insert(
            id = "a",
            payload = "{}".toByteArray(),
            leaseOwner = "dart:killed",
            leaseUntil = System.currentTimeMillis() + 60_000,
        )

        runWorker()

        assertEquals(0, server.requestCount)
        assertEquals(WorkInfo.State.ENQUEUED, state(BackgroundWork.RETRY))
    }

    @Test fun doesNothingWhenDisabled() {
        configure(enabled = false)
        db.insert(id = "a", payload = "{}".toByteArray())

        runWorker()

        assertEquals(0, server.requestCount)
        assertEquals(1L, eventCount())
    }

    @Test fun waitsForTheAppToMigrateAnOlderSchema() {
        db.raw.version = 1
        db.insert(id = "a", payload = "{}".toByteArray())

        runWorker()

        assertEquals(0, server.requestCount)
        assertTrue(logLines().single().contains("expected v2"))
    }

    @Test fun scheduleAndCancel() {
        BackgroundWork.schedule(context)
        assertEquals(WorkInfo.State.ENQUEUED, state(BackgroundWork.FLUSH))
        assertEquals(WorkInfo.State.ENQUEUED, state(BackgroundWork.PERIODIC))
        val constraints = WorkManager.getInstance(context)
            .getWorkInfosForUniqueWork(BackgroundWork.FLUSH).get().single().constraints
        assertEquals(androidx.work.NetworkType.CONNECTED, constraints.requiredNetworkType)

        BackgroundWork.cancelAll(context)
        assertEquals(WorkInfo.State.CANCELLED, state(BackgroundWork.FLUSH))
        assertEquals(WorkInfo.State.CANCELLED, state(BackgroundWork.PERIODIC))
    }
}
