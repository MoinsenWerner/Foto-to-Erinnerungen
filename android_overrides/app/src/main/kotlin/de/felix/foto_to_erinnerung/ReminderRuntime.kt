package de.felix.foto_to_erinnerung

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import kotlin.math.max

object ReminderRuntime {
    private const val STORE = "foto_alarm_native"
    private const val ENTRIES = "entries"
    private const val CHANNEL_ID = "foto_alarms_v1"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE)
    private fun alarms(ctx: Context) = ctx.getSystemService(AlarmManager::class.java)
    private fun code(id: Int, index: Int): Int = id * 4 + index

    fun load(ctx: Context): JSONArray = try {
        JSONArray(prefs(ctx).getString(ENTRIES, "[]"))
    } catch (_: Exception) { JSONArray() }

    fun saveAndReschedule(ctx: Context, entries: List<Map<String, Any?>>) {
        val old = load(ctx)
        cancelAll(ctx, old)
        val json = JSONArray()
        for (entry in entries) json.put(JSONObject(entry))
        prefs(ctx).edit().putString(ENTRIES, json.toString()).commit()
        reschedule(ctx, json)
    }

    fun reschedule(ctx: Context, entries: JSONArray = load(ctx)) {
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            scheduleOffset(ctx, item, 0)
            scheduleOffset(ctx, item, 1)
        }
    }

    private fun cancelAll(ctx: Context, entries: JSONArray) {
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val id = item.optInt("id")
            for (index in 0..1) {
                val pi = pending(ctx, id, index, false)
                if (pi != null) {
                    alarms(ctx).cancel(pi)
                    pi.cancel()
                }
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .cancel(code(id, index))
            }
        }
    }

    private fun pending(ctx: Context, id: Int, index: Int, create: Boolean): PendingIntent? {
        val intent = Intent(ctx, AlarmReceiver::class.java).apply {
            action = "de.felix.foto_to_erinnerung.ALARM"
            putExtra("id", id)
            putExtra("index", index)
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or
            (if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE)
        return PendingIntent.getBroadcast(ctx, code(id, index), intent, flags)
    }

    fun find(ctx: Context, id: Int): JSONObject? {
        val items = load(ctx)
        for (i in 0 until items.length()) {
            val event = items.optJSONObject(i) ?: continue
            if (event.optInt("id") == id) return event
        }
        return null
    }

    fun scheduleOffset(ctx: Context, item: JSONObject, index: Int) {
        val minutes = item.optJSONArray("minutes") ?: JSONArray("[7,5]")
        if (index >= minutes.length()) return
        val offset = minutes.optInt(index, if (index == 0) 7 else 5)
        val anchor = try { LocalDateTime.parse(item.getString("start")) } catch (_: Exception) { return }
        // Determine the next starting time AFTER (now + offset), so the trigger is in the future.
        val zone = ZoneId.systemDefault()
        val cutoff = ZonedDateTime.now(zone).plusMinutes(offset.toLong()).plusSeconds(1)
        val next = nextStart(item, anchor, cutoff) ?: return
        val at = next.minusMinutes(offset.toLong()).toInstant().toEpochMilli()
        val pi = pending(ctx, item.optInt("id"), index, true) ?: return
        val am = alarms(ctx)
        if (Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms()) {
            am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        } else {
            // Delivery may be late until special exact-alarm access is enabled.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi)
        }
    }

    private fun nextStart(item: JSONObject, anchor: LocalDateTime, cutoff: ZonedDateTime): ZonedDateTime? {
        val zone = ZoneId.systemDefault()
        val base = anchor.atZone(zone)
        if (!item.optBoolean("repeat", false)) return if (base.isAfter(cutoff)) base else null
        val every = max(1, item.optInt("every", 1))
        val unit = item.optString("unit", "days")
        val selection = mutableSetOf<Int>()
        val weekdays = item.optJSONArray("weekdays")
        if (weekdays != null) {
            for (i in 0 until weekdays.length()) selection.add(weekdays.optInt(i))
        }
        when (unit) {
            "hours" -> {
                val diffHours = max(0, ChronoUnit.HOURS.between(base.toInstant(), cutoff.toInstant()))
                var steps = max(0L, diffHours / every - 1L)
                repeat(3000) {
                    val next = base.plusHours(steps * every.toLong())
                    if (next.isAfter(cutoff) && (selection.isEmpty() || next.dayOfWeek.value in selection)) return next
                    steps++
                }
            }
            "weeks" -> {
                val firstMonday = anchor.toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                val weekDiff = max(0L, ChronoUnit.WEEKS.between(firstMonday, cutoff.toLocalDate()))
                var block = max(0L, weekDiff / every - 1)
                val days = if (selection.isEmpty()) listOf(anchor.dayOfWeek.value) else selection.sorted()
                repeat(100) {
                    val monday = firstMonday.plusWeeks(block * every.toLong())
                    for (day in days) {
                        if (day !in 1..7) continue
                        val next = LocalDateTime.of(monday.plusDays((day - 1).toLong()), anchor.toLocalTime()).atZone(zone)
                        if (!next.isBefore(base) && next.isAfter(cutoff)) return next
                    }
                    block++
                }
            }
            else -> { // days
                val diff = max(0L, ChronoUnit.DAYS.between(anchor.toLocalDate(), cutoff.toLocalDate()))
                var steps = max(0L, diff / every - 1L)
                repeat(1000) {
                    val next = anchor.plusDays(steps * every.toLong()).atZone(zone)
                    if (next.isAfter(cutoff) && (selection.isEmpty() || next.dayOfWeek.value in selection)) return next
                    steps++
                }
            }
        }
        return null
    }

    fun notification(ctx: Context, id: Int, index: Int, item: JSONObject): Notification {
        ensureChannel(ctx)
        val openIntent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val open = PendingIntent.getActivity(ctx, code(id, index), openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stopIntent = Intent(ctx, SoundService::class.java).apply { action = SoundService.STOP }
        val stop = PendingIntent.getService(ctx, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val mins = item.optJSONArray("minutes")?.optInt(index) ?: if (index == 0) 7 else 5
        return NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(item.optString("title", "Erinnerung"))
            .setContentText("Beginnt in $mins Minuten")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(android.R.drawable.ic_media_pause, "Ton stoppen", stop)
            .build()
    }

    private fun ensureChannel(ctx: Context) {
        val manager = ctx.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_ID, "Erinnerungsalarme", NotificationManager.IMPORTANCE_HIGH)
        channel.description = "Vorwarnungen vor Terminen"
        channel.setSound(null, null) // Sound is handled separately (system ringtone or MP3).
        channel.enableVibration(true)
        manager.createNotificationChannel(channel)
    }
}

class AlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra("id", -1)
        val index = intent.getIntExtra("index", -1)
        if (id < 0 || index !in 0..1) return
        val entry = ReminderRuntime.find(ctx, id) ?: return
        // Schedule future occurrences before playing, including if the app stays closed.
        try { ReminderRuntime.scheduleOffset(ctx, entry, index) } catch (_: Exception) { }
        val service = Intent(ctx, SoundService::class.java).apply {
            action = SoundService.PLAY
            putExtra("id", id)
            putExtra("index", index)
        }
        try {
            ContextCompat.startForegroundService(ctx, service)
        } catch (_: Exception) {
            // Devices with restricted FGS execution still get a normal notification.
            try {
                val manager = ctx.getSystemService(NotificationManager::class.java)
                manager.notify(id * 4 + index, ReminderRuntime.notification(ctx, id, index, entry))
            } catch (_: Exception) { }
        }
    }
}

class RestoreReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == Intent.ACTION_TIME_CHANGED ||
            intent.action == Intent.ACTION_TIMEZONE_CHANGED ||
            intent.action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED
        ) {
            ReminderRuntime.reschedule(ctx)
        }
    }
}

class SoundService : Service() {
    companion object { const val PLAY = "PLAY"; const val STOP = "STOP" }
    private val handler = Handler(Looper.getMainLooper())
    private val players = mutableListOf<MediaPlayer>()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            stopAll()
            stopSelf()
            return START_NOT_STICKY
        }
        val id = intent?.getIntExtra("id", -1) ?: -1
        val index = intent?.getIntExtra("index", -1) ?: -1
        val item = ReminderRuntime.find(this, id)
        if (item == null || index !in 0..1) { stopSelf(startId); return START_NOT_STICKY }
        val notification = ReminderRuntime.notification(this, id, index, item)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(990001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else startForeground(990001, notification)
        } catch (_: Exception) { stopSelf(startId); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(id * 4 + index, notification)
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= 31)
                getSystemService(VibratorManager::class.java).defaultVibrator
            else (getSystemService(VIBRATOR_SERVICE) as Vibrator)
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 450, 200, 450), -1))
        } catch (_: Exception) { }
        val sound = item.optString("soundValue", "")
        val type = item.optString("soundType", "default")
        try {
            val uri = if (type == "system" && sound.isNotEmpty()) Uri.parse(sound)
                else RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            val player = MediaPlayer()
            player.setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ALARM)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            if (type == "mp3" && File(sound).exists()) player.setDataSource(sound)
            else player.setDataSource(this, uri)
            player.isLooping = false
            player.setOnCompletionListener { p -> releasePlayer(p) }
            player.prepare()
            players.add(player)
            player.start()
            // Bound playback duration: avoid audio running indefinitely.
            handler.postDelayed({ releasePlayer(player) }, 30_000)
        } catch (_: Exception) { }
        handler.postDelayed({ if (players.isEmpty()) stopSelf(startId) }, 31_000)
        return START_NOT_STICKY
    }

    private fun releasePlayer(player: MediaPlayer) {
        if (players.remove(player)) {
            try { player.stop() } catch (_: Exception) { }
            try { player.release() } catch (_: Exception) { }
        }
    }
    private fun stopAll() { for (p in players.toList()) releasePlayer(p) }
    override fun onDestroy() { stopAll(); super.onDestroy() }
}
