package dev.beesync.bee_sync

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** spec/ directory, passed in by android/build.gradle. */
internal val specDir: File
    get() = File(requireNotNull(System.getProperty("beesync.specDir")) { "beesync.specDir not set" })

/** `-- name: x` sections of a spec SQL file, normalized (see spec_conformance_test.dart). */
internal fun parseSpec(file: File): Map<String, String> {
    val statements = LinkedHashMap<String, String>()
    var name: String? = null
    val buffer = StringBuilder()
    fun finish() {
        name?.let { statements[it] = normalizeSql(buffer.toString()) }
        buffer.clear()
    }
    for (line in file.readLines()) {
        val header = Regex("^-- name: (\\w+)").find(line)
        if (header != null) {
            finish()
            name = header.groupValues[1]
        } else if (!line.trimStart().startsWith("--")) {
            buffer.appendLine(line)
        }
    }
    finish()
    return statements
}

internal fun normalizeSql(s: String) = s.replace(Regex("\\s+"), " ").trim().removeSuffix(";")

/** A v2 database created the way the Dart side creates it, plus a raw handle. */
internal class TestDb(dir: File) {
    val path: String = File(dir, "bee_sync.db").absolutePath
    val raw: SQLiteDatabase = SQLiteDatabase.openDatabase(
        path,
        null,
        SQLiteDatabase.CREATE_IF_NECESSARY or SQLiteDatabase.ENABLE_WRITE_AHEAD_LOGGING,
    ).also { db ->
        Sql.schemaStatements.values.forEach(db::execSQL)
        db.version = Sql.SCHEMA_VERSION
    }

    fun insert(
        id: String,
        payload: ByteArray,
        name: String = "evt",
        priority: Int = 0,
        createdAt: Long = 0,
        attempts: Int = 0,
        nextAttemptAt: Long = 0,
        leaseOwner: String? = null,
        leaseUntil: Long? = null,
    ) {
        raw.insertOrThrow(
            "events",
            null,
            ContentValues().apply {
                put("id", id)
                put("name", name)
                put("payload", payload)
                put("encrypted", 0)
                put("priority", priority)
                put("created_at", createdAt)
                put("size_bytes", payload.size)
                put("attempts", attempts)
                put("next_attempt_at", nextAttemptAt)
                put("lease_owner", leaseOwner)
                put("lease_until", leaseUntil)
            },
        )
    }

    fun setMeta(key: String, value: String) = raw.execSQL(Sql.SET_META, arrayOf(key, value))

    fun meta(key: String): String? =
        raw.rawQuery(Sql.GET_META, arrayOf(key)).use { if (it.moveToFirst()) it.getString(0) else null }

    fun close() = raw.close()
}

/** JSON -> plain Kotlin values, for structural equality. */
internal fun toPlain(value: Any?): Any? = when (value) {
    is JSONObject -> value.keys().asSequence().associateWith { toPlain(value.get(it)) }
    is JSONArray -> (0 until value.length()).map { toPlain(value.get(it)) }
    JSONObject.NULL -> null
    is Int -> value.toLong()
    else -> value
}
