package dev.beesync.bee_sync

import android.content.Context
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters

/**
 * Uploads queued events while the Flutter app is not running. Runs entirely
 * natively (no Flutter engine) against the database path Dart recorded.
 *
 * Always returns success: retries are driven by the contract's own backoff
 * (meta.flush_not_before) via [BackgroundWork.scheduleRetry], not by
 * WorkManager's.
 */
internal class FlushWorker(context: Context, params: WorkerParameters) : Worker(context, params) {

    /** Replaced in tests. */
    internal var sender: HttpSender = UrlConnectionSender()

    override fun doWork(): Result {
        val prefs = applicationContext.getSharedPreferences(BeeSyncPlugin.PREFS, Context.MODE_PRIVATE)
        val path = prefs.getString(BeeSyncPlugin.KEY_DATABASE_PATH, null)
        if (path == null || !prefs.getBoolean(BeeSyncPlugin.KEY_ENABLED, false)) {
            return Result.success()
        }

        val store = try {
            BeeSyncStore.open(path)
        } catch (e: Exception) {
            Log.w(TAG, "Cannot open bee_sync database", e)
            null
        } ?: return Result.success()

        store.use { s ->
            val now = System.currentTimeMillis()
            if (s.schemaVersion != Sql.SCHEMA_VERSION) {
                // Dart migrates on the app's next launch; until then, do nothing.
                s.log(
                    now,
                    SOURCE,
                    "warn",
                    "Schema v${s.schemaVersion}, expected v${Sql.SCHEMA_VERSION}; waiting for app launch",
                )
                s.trimLog(LOG_KEEP)
                return Result.success()
            }

            val result = try {
                // Every job requires a network connection, so a backoff caused
                // by network failures is over (§2).
                NativeUploader(s, sender, SOURCE)
                    .run(networkAvailable = true, shouldContinue = { !isStopped })
            } catch (e: Exception) {
                Log.w(TAG, "Background upload failed", e)
                s.log(System.currentTimeMillis(), SOURCE, "error", "Upload failed: ${e.javaClass.simpleName}")
                s.trimLog(LOG_KEEP)
                return Result.success()
            }

            logResult(s, result)
            followUp(s, result)
        }
        return Result.success()
    }

    private fun logResult(store: BeeSyncStore, result: RunResult) {
        val at = System.currentTimeMillis()
        val summary = "${result.status.name.lowercase()}: sent ${result.delivered}, dropped ${result.dropped}"
        when (result.status) {
            RunStatus.DRAINED -> store.log(at, SOURCE, "info", summary)
            RunStatus.BACKING_OFF, RunStatus.AUTH_BLOCKED ->
                store.log(at, SOURCE, "warn", "$summary (${result.error})")
            // Skips (consent, auth block, backoff) are routine; only note them at debug.
            RunStatus.SKIPPED -> store.log(at, SOURCE, "debug", "skipped: ${result.error ?: "stopped"}")
        }
        store.trimLog(LOG_KEEP)
    }

    private fun followUp(store: BeeSyncStore, result: RunResult) {
        if (store.countEvents() == 0L) {
            BackgroundWork.cancelPeriodic(applicationContext)
            return
        }
        // Set both when this run backed off and when it was skipped because an
        // earlier run (possibly the app's own) is still backing off.
        val retryAt = result.retryAt ?: if (result.status == RunStatus.DRAINED) {
            // Events remain but none was claimable: another uploader holds them,
            // typically the app, killed mid-request. Come back once that lease
            // has expired instead of waiting for the 15-minute periodic job.
            System.currentTimeMillis() +
                DeliverySettings.parse(store.getMeta(MetaKeys.DELIVERY_CONFIG)).leaseMs
        } else {
            null
        }
        if (retryAt != null) {
            BackgroundWork.scheduleRetry(applicationContext, retryAt - System.currentTimeMillis())
        }
        // Otherwise (e.g. auth blocked) the periodic job picks the rest up.
    }

    companion object {
        const val SOURCE = "android_worker"
        const val LOG_KEEP = 200
        private const val TAG = "bee_sync"
    }
}
