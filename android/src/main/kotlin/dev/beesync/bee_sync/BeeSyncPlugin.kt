package dev.beesync.bee_sync

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Receives the database location from Dart and schedules background flushes.
 *
 * Placeholder until the WorkManager uploader lands (v0.2 step 3): it stores
 * the setup so a cold-started worker can find the database, and schedules
 * nothing yet.
 */
class BeeSyncPlugin : FlutterPlugin, BeeSyncHostApi {
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        BeeSyncHostApi.setUp(binding.binaryMessenger, this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        BeeSyncHostApi.setUp(binding.binaryMessenger, null)
    }

    override fun configure(setup: BackgroundSetup): List<String> {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_DATABASE_PATH, setup.databasePath)
            .putBoolean(KEY_ENABLED, setup.enabled)
            .apply()
        return emptyList()
    }

    override fun scheduleBackgroundFlush() {}

    override fun cancelBackgroundFlush() {}

    companion object {
        const val PREFS = "dev.beesync.bee_sync"
        const val KEY_DATABASE_PATH = "database_path"
        const val KEY_ENABLED = "background_enabled"
    }
}
