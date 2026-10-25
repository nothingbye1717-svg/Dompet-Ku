package com.dompetku.dompetku

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Lists apps Android exposes, plus explicitly declared financial apps and user-added package IDs. */
class MainActivity : FlutterActivity() {
    private val channelName = "com.dompetku.notification_tracker"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "listApps" -> result.success(listVisibleApps())
                        "getSelected" -> result.success(TrackerStore.selected(this).toList())
                        "setSelected" -> {
                            val names = call.arguments as? List<*>
                            if (names == null || names.any { it !is String }) {
                                result.error("INVALID", "Expected a list of app package names", null)
                            } else {
                                TrackerStore.setSelected(this, names.filterIsInstance<String>().toSet())
                                result.success(null)
                            }
                        }
                        "addCustomApp" -> {
                            val pkg = call.argument<String>("package")?.trim().orEmpty()
                            val name = call.argument<String>("name")?.trim().orEmpty()
                            if (!isValidPackageName(pkg) || name.isEmpty() || name.length > 60) {
                                result.error("INVALID", "Enter a valid app package ID and display name", null)
                            } else {
                                TrackerStore.addCustomApp(this, pkg, name)
                                result.success(null)
                            }
                        }
                        "removeCustomApp" -> {
                            val pkg = call.argument<String>("package")?.trim().orEmpty()
                            if (!isValidPackageName(pkg)) {
                                result.error("INVALID", "Invalid package ID", null)
                            } else {
                                TrackerStore.removeCustomApp(this, pkg)
                                result.success(null)
                            }
                        }
                        "accessEnabled" -> result.success(isListenerEnabled())
                        "openAccessSettings" -> {
                            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                            result.success(null)
                        }
                        "getPending" -> result.success(TrackerStore.pending(this))
                        "consume" -> {
                            val ids = (call.arguments as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                            TrackerStore.consume(this, ids.toSet())
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("TRACKER", e.message ?: "Unknown Android error", null)
                }
            }
    }

    private fun isValidPackageName(value: String): Boolean =
        value.length in 3..200 &&
            Regex("^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$").matches(value)

    private fun listVisibleApps(): List<Map<String, Any>> {
        val apps = linkedMapOf<String, Map<String, Any>>()
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        @Suppress("DEPRECATION")
        val activities = packageManager.queryIntentActivities(intent, 0)
        for (activity in activities) {
            val pkg = activity.activityInfo?.packageName ?: continue
            if (pkg == packageName || apps.containsKey(pkg)) continue
            apps[pkg] = mapOf(
                "package" to pkg,
                "name" to activity.loadLabel(packageManager).toString(),
                "installed" to true,
                "manual" to false
            )
        }

        // myBSN is declared explicitly in <queries> to avoid Android 11+ visibility filtering.
        // This package ID comes from the bank's Google Play listing.
        val known = mapOf("com.bsn.mybsn" to "myBSN")
        for ((pkg, fallbackName) in known) {
            val installed = try {
                @Suppress("DEPRECATION")
                val info = packageManager.getApplicationInfo(pkg, 0)
                val actualName = packageManager.getApplicationLabel(info).toString()
                apps[pkg] = mapOf("package" to pkg, "name" to actualName,
                    "installed" to true, "manual" to false)
                true
            } catch (_: PackageManager.NameNotFoundException) { false }
            if (!installed && !apps.containsKey(pkg)) {
                apps[pkg] = mapOf("package" to pkg, "name" to fallbackName,
                    "installed" to false, "manual" to false)
            }
        }

        // User-entered package IDs do not need QUERY_ALL_PACKAGES. NotificationListenerService
        // can match an exact notification source package after the user explicitly opts in.
        for ((pkg, name) in TrackerStore.customApps(this)) {
            if (pkg == packageName) continue
            if (!apps.containsKey(pkg)) {
                apps[pkg] = mapOf("package" to pkg, "name" to name,
                    "installed" to true, "manual" to true)
            }
        }
        for (pkg in TrackerStore.selected(this)) {
            if (pkg != packageName && !apps.containsKey(pkg)) {
                apps[pkg] = mapOf("package" to pkg, "name" to pkg,
                    "installed" to true, "manual" to true)
            }
        }
        return apps.values.sortedWith(
            compareBy<Map<String, Any>> { if (it["package"] == "com.bsn.mybsn") 0 else 1 }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { it["name"].toString() }
        )
    }

    private fun isListenerEnabled(): Boolean {
        val enabled = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
        val expected = ComponentName(this, BankNotificationListener::class.java)
        return enabled.split(":").any { ComponentName.unflattenFromString(it) == expected }
    }
}
