package dev.beesync.bee_sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * WorkManager scheduling (docs/DESIGN.md §7.1):
 * - [FLUSH]: one-time, as soon as there is network, when the app backgrounds
 *   with events still queued.
 * - [PERIODIC]: every 15 minutes (the OS minimum) while events remain.
 * - [RETRY]: one-time, delayed until the global backoff ends.
 */
internal object BackgroundWork {
    const val FLUSH = "bee_sync_flush"
    const val PERIODIC = "bee_sync_periodic"
    const val RETRY = "bee_sync_retry"

    private val networkConstraint =
        Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    fun schedule(context: Context) {
        val wm = WorkManager.getInstance(context)
        wm.enqueueUniqueWork(
            FLUSH,
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<FlushWorker>().setConstraints(networkConstraint).build(),
        )
        wm.enqueueUniquePeriodicWork(
            PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<FlushWorker>(15, TimeUnit.MINUTES)
                .setConstraints(networkConstraint)
                .build(),
        )
    }

    /** Runs once more after [delayMs], replacing any earlier retry. */
    fun scheduleRetry(context: Context, delayMs: Long) {
        WorkManager.getInstance(context).enqueueUniqueWork(
            RETRY,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<FlushWorker>()
                .setConstraints(networkConstraint)
                .setInitialDelay(delayMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
                .build(),
        )
    }

    /** The queue is empty: nothing left to run for. */
    fun cancelPeriodic(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC)
    }

    fun cancelAll(context: Context) {
        val wm = WorkManager.getInstance(context)
        wm.cancelUniqueWork(FLUSH)
        wm.cancelUniqueWork(PERIODIC)
        wm.cancelUniqueWork(RETRY)
    }
}
