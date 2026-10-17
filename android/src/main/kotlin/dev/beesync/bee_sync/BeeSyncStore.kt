package dev.beesync.bee_sync

import android.database.sqlite.SQLiteDatabase
import java.io.Closeable
import java.io.File

/** A row returned by [BeeSyncStore.claim]. */
internal class StoredEvent(
    val seq: Long,
    val id: String,
    val name: String,
    val payload: ByteArray,
    val encrypted: Boolean,
    val priority: Int,
    val createdAt: Long,
    val sizeBytes: Int,
    val attempts: Int,
)

/**
 * Native access to bee_sync.db, which the Dart side creates and migrates.
 * Implements the claim protocol in spec/claim_protocol.sql.
 */
internal class BeeSyncStore private constructor(private val db: SQLiteDatabase) : Closeable {

    companion object {
        /**
         * Opens an existing database, or returns null when Dart has not created
         * it yet. Never creates the file: only Dart owns the schema.
         */
        fun open(path: String): BeeSyncStore? {
            if (!File(path).exists()) return null
            // ENABLE_WRITE_AHEAD_LOGGING keeps the file in WAL mode, which the
            // Dart connection relies on; without it Android would switch the
            // journal mode on open. NO_LOCALIZED_COLLATORS avoids creating
            // android_metadata.
            val db = SQLiteDatabase.openDatabase(
                path,
                null,
                SQLiteDatabase.OPEN_READWRITE or
                    SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING or
                    SQLiteDatabase.NO_LOCALIZED_COLLATORS,
            )
            db.rawQuery("PRAGMA busy_timeout = 5000", null).use { it.moveToFirst() }
            return BeeSyncStore(db)
        }
    }

    /** PRAGMA user_version; uploaders only run when it equals [Sql.SCHEMA_VERSION]. */
    val schemaVersion: Int get() = db.version

    /** Leases up to [limit] ready rows to [owner] and returns all rows it holds. */
    fun claim(owner: String, now: Long, leaseUntil: Long, limit: Int): List<StoredEvent> =
        transaction {
            db.execSQL(Sql.CLAIM, arrayOf<Any>(owner, leaseUntil, now, now, 0, limit))
            db.rawQuery(Sql.SELECT_CLAIMED, arrayOf(owner)).use { c ->
                buildList {
                    while (c.moveToNext()) {
                        add(
                            StoredEvent(
                                seq = c.getLong(0),
                                id = c.getString(1),
                                name = c.getString(2),
                                payload = c.getBlob(3),
                                encrypted = c.getInt(4) == 1,
                                priority = c.getInt(5),
                                createdAt = c.getLong(6),
                                sizeBytes = c.getInt(7),
                                attempts = c.getInt(8),
                            ),
                        )
                    }
                }
            }
        }

    /** Deletes leased rows and adds [counters] in the same transaction. */
    fun deleteLeased(owner: String, ids: List<String>, counters: Map<String, Int> = emptyMap()) {
        if (ids.isEmpty() && counters.isEmpty()) return
        transaction {
            if (ids.isNotEmpty()) {
                db.execSQL(Sql.expandIds(Sql.DELETE_LEASED, ids.size), arrayOf<Any>(owner, *ids.toTypedArray()))
            }
            incrementCounters(counters)
        }
    }

    fun releaseRetry(owner: String, ids: List<String>, nextAttemptAt: Long) {
        if (ids.isEmpty()) return
        db.execSQL(
            Sql.expandIds(Sql.RELEASE_RETRY, ids.size),
            arrayOf<Any>(nextAttemptAt, owner, *ids.toTypedArray()),
        )
    }

    fun release(owner: String, ids: List<String>) {
        if (ids.isEmpty()) return
        db.execSQL(Sql.expandIds(Sql.RELEASE, ids.size), arrayOf<Any>(owner, *ids.toTypedArray()))
    }

    fun getMeta(key: String): String? =
        db.rawQuery(Sql.GET_META, arrayOf(key)).use { c -> if (c.moveToFirst()) c.getString(0) else null }

    fun setMeta(key: String, value: String) {
        db.execSQL(Sql.SET_META, arrayOf<Any>(key, value))
    }

    fun countEvents(): Long =
        db.rawQuery(Sql.COUNT_EVENTS, null).use { c -> if (c.moveToFirst()) c.getLong(0) else 0 }

    fun counters(): Map<String, Long> =
        db.rawQuery(Sql.SELECT_COUNTERS, null).use { c ->
            buildMap { while (c.moveToNext()) put(c.getString(0), c.getLong(1)) }
        }

    fun log(at: Long, source: String, level: String, message: String) {
        db.execSQL(Sql.INSERT_BG_LOG, arrayOf<Any>(at, source, level, message))
    }

    fun trimLog(keep: Int) {
        db.execSQL(Sql.TRIM_BG_LOG, arrayOf<Any>(keep))
    }

    override fun close() = db.close()

    private fun incrementCounters(deltas: Map<String, Int>) {
        for ((key, delta) in deltas) {
            if (delta == 0) continue
            db.execSQL(Sql.ENSURE_COUNTER, arrayOf<Any>(key))
            db.execSQL(Sql.INCREMENT_COUNTER, arrayOf<Any>(delta, key))
        }
    }

    /** BEGIN IMMEDIATE ... COMMIT, as the claim protocol requires. */
    private inline fun <T> transaction(block: () -> T): T {
        db.beginTransactionNonExclusive()
        try {
            val result = block()
            db.setTransactionSuccessful()
            return result
        } finally {
            db.endTransaction()
        }
    }
}
