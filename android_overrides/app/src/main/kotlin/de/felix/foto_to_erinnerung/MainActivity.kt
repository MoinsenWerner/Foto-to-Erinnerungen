package de.felix.foto_to_erinnerung

import android.Manifest
import android.app.AlarmManager
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "foto_to_erinnerung/android"
    private var ringResult: MethodChannel.Result? = null
    private val ringRequest = 9421

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "scheduleAll" -> {
                            val entries = call.argument<List<Map<String, Any?>>>("entries") ?: emptyList()
                            val showNext = call.argument<Boolean>("showNextNotification") ?: false
                            val vibrateOnly = call.argument<Boolean>("vibrateOnly") ?: false
                            ReminderRuntime.saveAndReschedule(this, entries, showNext, vibrateOnly)
                            WearPhoneSync.publish(this, org.json.JSONArray().apply {
                                entries.forEach { put(org.json.JSONObject(it)) }
                            }.toString())
                            result.success(null)
                        }
                        "refreshNextNotification" -> {
                            ReminderRuntime.updateNextNotification(this)
                            result.success(null)
                        }
                        "openNotificationSettings" -> {
                            startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            })
                            result.success(null)
                        }
                        "canExactAlarms" -> {
                            val manager = getSystemService(AlarmManager::class.java)
                            result.success(Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms())
                        }
                        "openAlarmSettings" -> {
                            if (Build.VERSION.SDK_INT >= 31) {
                                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                                    data = android.net.Uri.parse("package:$packageName")
                                })
                            }
                            result.success(null)
                        }
                        "requestNotificationPermission" -> {
                            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(
                                    this, Manifest.permission.POST_NOTIFICATIONS
                                ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                ActivityCompat.requestPermissions(this,
                                    arrayOf(Manifest.permission.POST_NOTIFICATIONS), 9422)
                            }
                            result.success(null)
                        }
                        "chooseAlarmSound" -> {
                            if (ringResult != null) {
                                result.error("BUSY", "Die Klingeltonauswahl ist bereits geöffnet.", null)
                            } else {
                                ringResult = result
                                val intent = Intent(RingtoneManager.ACTION_RINGTONE_PICKER).apply {
                                    putExtra(RingtoneManager.EXTRA_RINGTONE_TYPE, RingtoneManager.TYPE_ALARM)
                                    putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_DEFAULT, true)
                                    putExtra(RingtoneManager.EXTRA_RINGTONE_SHOW_SILENT, false)
                                    putExtra(RingtoneManager.EXTRA_RINGTONE_TITLE, "System-Weckerton auswählen")
                                }
                                startActivityForResult(intent, ringRequest)
                            }
                        }
                        else -> result.notImplemented()
                    }
                } catch (ex: Exception) {
                    result.error("ANDROID", ex.message ?: "Android-Fehler", null)
                }
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int, permissions: Array<out String>, grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9422) ReminderRuntime.updateNextNotification(this)
    }

    @Deprecated("Platform callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == ringRequest) {
            val callback = ringResult
            ringResult = null
            if (resultCode != RESULT_OK) {
                callback?.success(null)
                return
            }
            @Suppress("DEPRECATION")
            val uri = data?.getParcelableExtra<android.net.Uri>(RingtoneManager.EXTRA_RINGTONE_PICKED_URI)
            val title = uri?.let { RingtoneManager.getRingtone(this, it)?.getTitle(this) } ?: "System-Weckerton"
            callback?.success(mapOf("type" to "system", "value" to (uri?.toString() ?: ""), "label" to title))
        }
    }
}
