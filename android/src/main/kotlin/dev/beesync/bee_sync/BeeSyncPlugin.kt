package dev.beesync.bee_sync

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Dart -> native bridge (pigeons/messages.dart). Records where the database
 * is, so a cold-started [FlushWorker] can find it, and schedules background
 * flushes through [BackgroundWork].
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
        if (!setup.enabled) BackgroundWork.cancelAll(context)
        return emptyList()
    }

    override fun scheduleBackgroundFlush() = BackgroundWork.schedule(context)

    override fun cancelBackgroundFlush() = BackgroundWork.cancelAll(context)

    companion object {
        const val PREFS = "dev.beesync.bee_sync"
        const val KEY_DATABASE_PATH = "database_path"
        const val KEY_ENABLED = "background_enabled"
    }
}
