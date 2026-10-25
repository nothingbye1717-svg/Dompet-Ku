package com.dompetku.dompetku

import android.app.Notification
import android.content.Context
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.security.MessageDigest
import java.util.concurrent.Executors
import org.json.JSONArray
import org.json.JSONObject

/** On-device, opt-in transaction *suggestion* extractor. No raw notification is stored/transmitted. */
class BankNotificationListener : NotificationListenerService() {
    // Android delivers listener callbacks on the main thread. Process the
    // private transaction metadata on a worker to keep the UI responsive.
    private val worker = Executors.newSingleThreadExecutor()

    override fun onDestroy() {
        worker.shutdown()
        super.onDestroy()
    }
    override fun onNotificationPosted(sbn: StatusBarNotification) {
        try {
            // Read the package first, before accessing notification title/text.
            val chosen = TrackerStore.selected(this)
            if (!chosen.contains(sbn.packageName)) return
            if ((sbn.notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return

            val extras = sbn.notification.extras ?: return
            val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
            val body = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
                ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
            if (body.isBlank() || body.length > 4096) return
            val appPackage = sbn.packageName
            val notificationId = sbn.id
            val postedAt = sbn.postTime
            worker.execute {
                try {
                    val parsed = TransactionParser.parse(title, body) ?: return@execute
                    val source = try {
                        @Suppress("DEPRECATION")
                        val info = packageManager.getApplicationInfo(appPackage, 0)
                        packageManager.getApplicationLabel(info).toString().take(50)
                    } catch (_: Exception) { "Aplikasi kewangan" }
                    val timestamp = if (postedAt > 0) postedAt else System.currentTimeMillis()
                    val duplicateKey = "$appPackage|$notificationId|$title|$body|${timestamp / 120000L}"
                    val digest = MessageDigest.getInstance("SHA-256")
                        .digest(duplicateKey.toByteArray(Charsets.UTF_8))
                        .joinToString("") { "%02x".format(it) }
                    val item = JSONObject()
                        .put("id", digest)
                        .put("source", source)
                        .put("amount", parsed.amount)
                        .put("direction", parsed.direction)
                        .put("merchant", parsed.merchant)
                        .put("timestamp", timestamp)
                    TrackerStore.add(this, item)
                } catch (_: Exception) {
                    // One malformed notification must not disrupt Android UI.
                }
            }
        } catch (_: Exception) {
            // Parsing errors must not affect other applications or Android's notification UI.
        }
    }
}

internal object TrackerStore {
    private const val preferenceFile = "dompetku_auto_track_v2"
    private const val appsKey = "selected_apps"
    private const val pendingKey = "pending_transactions"
    private const val seenKey = "seen_ids"
    private const val customKey = "custom_apps"
    private val lock = Any()

    /** Only stores package IDs and user-provided labels; no notification text. */
    fun customApps(context: Context): Map<String, String> = synchronized(lock) {
        val raw = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            .getString(customKey, "{}") ?: "{}"
        val json = try { JSONObject(raw) } catch (_: Exception) { JSONObject() }
        val out = linkedMapOf<String, String>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val pkg = keys.next()
            out[pkg] = json.optString(pkg, pkg)
        }
        out
    }

    fun addCustomApp(context: Context, pkg: String, name: String) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            val json = try { JSONObject(prefs.getString(customKey, "{}") ?: "{}") }
                catch (_: Exception) { JSONObject() }
            json.put(pkg, name)
            prefs.edit().putString(customKey, json.toString()).apply()
        }
    }

    fun removeCustomApp(context: Context, pkg: String) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            val json = try { JSONObject(prefs.getString(customKey, "{}") ?: "{}") }
                catch (_: Exception) { JSONObject() }
            json.remove(pkg)
            val next = selected(context).minus(pkg)
            prefs.edit().putString(customKey, json.toString())
                .putStringSet(appsKey, next).apply()
        }
    }

    fun selected(context: Context): Set<String> =
        context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            .getStringSet(appsKey, emptySet())?.toSet() ?: emptySet()

    fun setSelected(context: Context, values: Set<String>) {
        synchronized(lock) {
            context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
                .edit().putStringSet(appsKey, values).apply()
        }
    }

    fun pending(context: Context): List<Map<String, Any>> = synchronized(lock) {
        val prefs = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
        val queue = JSONArray(prefs.getString(pendingKey, "[]"))
        (0 until queue.length()).mapNotNull { i ->
            val item = queue.optJSONObject(i) ?: return@mapNotNull null
            mapOf(
                "id" to item.optString("id"),
                "source" to item.optString("source"),
                "merchant" to item.optString("merchant"),
                "direction" to item.optString("direction"),
                "amount" to item.optDouble("amount", 0.0),
                "timestamp" to item.optLong("timestamp", 0L)
            )
        }
    }

    fun add(context: Context, record: JSONObject) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            val id = record.optString("id")
            if (id.isEmpty()) return
            val seen = JSONArray(prefs.getString(seenKey, "[]"))
            for (i in 0 until seen.length()) if (seen.optString(i) == id) return
            val queue = JSONArray(prefs.getString(pendingKey, "[]"))
            queue.put(record)
            seen.put(id)
            val recent = JSONArray()
            for (i in maxOf(0, queue.length() - 150) until queue.length()) recent.put(queue.get(i))
            val recentIds = JSONArray()
            for (i in maxOf(0, seen.length() - 750) until seen.length()) recentIds.put(seen.get(i))
            prefs.edit().putString(pendingKey, recent.toString())
                .putString(seenKey, recentIds.toString()).apply()
        }
    }

    fun consume(context: Context, ids: Set<String>) {
        synchronized(lock) {
            val prefs = context.getSharedPreferences(preferenceFile, Context.MODE_PRIVATE)
            val queue = JSONArray(prefs.getString(pendingKey, "[]"))
            val updated = JSONArray()
            for (i in 0 until queue.length()) {
                val item = queue.optJSONObject(i) ?: continue
                if (item.optString("id") !in ids) updated.put(item)
            }
            prefs.edit().putString(pendingKey, updated.toString()).apply()
        }
    }
}
