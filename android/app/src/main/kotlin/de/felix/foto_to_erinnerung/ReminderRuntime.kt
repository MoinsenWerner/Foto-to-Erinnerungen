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
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
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
    private const val VIBRATE_CHANNEL_ID = "foto_alarms_vibrate_v1"
    private const val NEXT_CHANNEL_ID = "foto_next_status_v1"
    private const val NEXT_NOTIFICATION_ID = 990002
    private const val NEXT_REFRESH_CODE = 990003
    private const val STATUS_ENABLED = "show_next_notification"
    private const val VIBRATE_ONLY = "vibrate_only"
    private const val MAX_OFFSETS = 32

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE)
    private fun alarms(ctx: Context) = ctx.getSystemService(AlarmManager::class.java)
    // Unique for every reminder/offset pair (legacy id*4+index collided after 2 offsets).
    private fun code(id: Int, index: Int): Int = "fte:$id:$index".hashCode()
    private fun legacyCode(id: Int, index: Int): Int = id * 4 + index

    fun load(ctx: Context): JSONArray = try {
        JSONArray(prefs(ctx).getString(ENTRIES, "[]"))
    } catch (_: Exception) { JSONArray() }

    fun saveAndReschedule(
        ctx: Context, entries: List<Map<String, Any?>>,
        showNextNotification: Boolean, vibrateOnly: Boolean
    ) {
        val old = load(ctx)
        cancelAll(ctx, old)
        val json = JSONArray()
        for (entry in entries) json.put(JSONObject(entry))
        // Native persistence allows status updates when the Flutter UI is closed.
        prefs(ctx).edit()
            .putString(ENTRIES, json.toString())
            .putBoolean(STATUS_ENABLED, showNextNotification)
            .putBoolean(VIBRATE_ONLY, vibrateOnly)
            .commit()
        reschedule(ctx, json)
        if (vibrateOnly) {
            // Stop audio that may still be playing from an earlier alarm.
            ctx.stopService(Intent(ctx, SoundService::class.java))
        }
    }

    fun isVibrateOnly(ctx: Context): Boolean = prefs(ctx).getBoolean(VIBRATE_ONLY, false)
    private fun isNextEnabled(ctx: Context): Boolean = prefs(ctx).getBoolean(STATUS_ENABLED, false)

    fun reschedule(ctx: Context, entries: JSONArray = load(ctx)) {
        // Cancel old-version alarms on upgrade or system restore.
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val id = item.optInt("id")
            for (index in 0..1) {
                val old = legacyPending(ctx, id, index)
                if (old != null) {
                    alarms(ctx).cancel(old)
                    old.cancel()
                }
            }
        }
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val count = minOf(MAX_OFFSETS, (item.optJSONArray("minutes") ?: JSONArray("[7,5]")).length())
            for (index in 0 until count) scheduleOffset(ctx, item, index)
        }
        updateNextNotification(ctx)
    }

    private fun cancelAll(ctx: Context, entries: JSONArray) {
        val manager = ctx.getSystemService(NotificationManager::class.java)
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val id = item.optInt("id")
            val count = minOf(MAX_OFFSETS, (item.optJSONArray("minutes") ?: JSONArray("[7,5]")).length())
            for (index in 0 until count) {
                val pi = pending(ctx, id, index, false)
                if (pi != null) {
                    alarms(ctx).cancel(pi)
                    pi.cancel()
                }
                manager.cancel(code(id, index))
            }
            // Cancel alarms created by earlier releases (id*4+index, index 0/1).
            for (index in 0..1) {
                val old = legacyPending(ctx, id, index)
                if (old != null) {
                    alarms(ctx).cancel(old)
                    old.cancel()
                }
                manager.cancel(legacyCode(id, index))
            }
        }
    }

    private fun legacyPending(ctx: Context, id: Int, index: Int): PendingIntent? {
        val intent = Intent(ctx, AlarmReceiver::class.java).apply {
            action = "de.felix.foto_to_erinnerung.ALARM"
            putExtra("id", id)
            putExtra("index", index)
        }
        return PendingIntent.getBroadcast(ctx, legacyCode(id, index), intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_NO_CREATE)
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
        if (index < 0 || index >= MAX_OFFSETS || index >= minutes.length()) return
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

    // Separate, permanently quiet channel. It never uses the reminder's ringtone.
    private fun ensureNextChannel(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NEXT_CHANNEL_ID, "Nächste Erinnerungen", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Ständige, lautlose Übersicht über die nächsten Termine"
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun refreshPending(ctx: Context): PendingIntent {
        val intent = Intent(ctx, NextNotificationReceiver::class.java).apply {
            action = "de.felix.foto_to_erinnerung.REFRESH_NEXT"
        }
        return PendingIntent.getBroadcast(
            ctx, NEXT_REFRESH_CODE, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun nextItems(ctx: Context): List<Pair<ZonedDateTime, JSONObject>> {
        val now = ZonedDateTime.now(ZoneId.systemDefault())
        val found = mutableListOf<Pair<ZonedDateTime, JSONObject>>()
        val entries = load(ctx)
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val anchor = try {
                LocalDateTime.parse(item.getString("start"))
            } catch (_: Exception) { continue }
            var threshold = now.minusNanos(1)
            // Also list multiple upcoming occurrences of a recurring reminder,
            // not only the first occurrence of each reminder definition.
            for (index in 0 until 4) {
                val next = nextStart(item, anchor, threshold) ?: break
                found.add(Pair(next, item))
                if (!item.optBoolean("repeat", false)) break
                threshold = next.plusNanos(1)
            }
        }
        found.sortBy { it.first.toInstant() }
        return found.take(4)
    }

    private fun formatStart(time: ZonedDateTime): String {
        val format = SimpleDateFormat("EEE dd.MM. HH:mm", Locale.GERMAN)
        return format.format(Date.from(time.toInstant()))
    }

    fun updateNextNotification(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        // Cancel the old refresh alarm before planning a new one.
        val alarm = alarms(ctx)
        val refresh = refreshPending(ctx)
        alarm.cancel(refresh)
        if (!isNextEnabled(ctx)) {
            nm.cancel(NEXT_NOTIFICATION_ID)
            return
        }

        val next = nextItems(ctx)
        ensureNextChannel(ctx)
        val open = PendingIntent.getActivity(
            ctx, NEXT_NOTIFICATION_ID,
            Intent(ctx, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val title = if (next.isEmpty()) "Keine anstehenden Erinnerungen"
            else "${formatStart(next.first().first)} · ${next.first().second.optString("title", "Erinnerung")}"
        // Separater Stil statt .apply: NotificationCompat.Style hat selbst eine apply()-Methode.
        val inboxStyle = NotificationCompat.InboxStyle()
        if (next.isEmpty()) {
            inboxStyle.addLine("Keine anstehenden Erinnerungen")
        } else {
            for ((whenAt, item) in next) {
                inboxStyle.addLine("${formatStart(whenAt)} · ${item.optString("title", "Erinnerung")}")
            }
        }

        val notification = NotificationCompat.Builder(ctx, NEXT_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("Nächste Erinnerungen")
            .setContentText(title)
            .setStyle(inboxStyle)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            .build()
        try {
            nm.notify(NEXT_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // On Android 13+ the user can deny POST_NOTIFICATIONS.
        }

        if (next.isNotEmpty()) {
            // The previous appointment is no longer the next one at its start.
            val whenMillis = max(
                System.currentTimeMillis() + 1000L,
                next.first().first.toInstant().toEpochMilli() + 1000L
            )
            try {
                if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) {
                    alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMillis, refresh)
                } else {
                    alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMillis, refresh)
                }
            } catch (_: SecurityException) {
                alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, whenMillis, refresh)
            }
        }
    }

    fun vibrate(ctx: Context) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= 31)
                ctx.getSystemService(VibratorManager::class.java).defaultVibrator
            else (ctx.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator)
            vibrator.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 450, 200, 450), -1))
        } catch (_: Exception) { }
    }

    fun notification(ctx: Context, id: Int, index: Int, item: JSONObject, silent: Boolean = false): Notification {
        if (silent) ensureVibrateChannel(ctx) else ensureChannel(ctx)
        val openIntent = Intent(ctx, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val open = PendingIntent.getActivity(ctx, code(id, index), openIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stopIntent = Intent(ctx, SoundService::class.java).apply { action = SoundService.STOP }
        val stop = PendingIntent.getService(ctx, 0, stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val mins = item.optJSONArray("minutes")?.optInt(index) ?: if (index == 0) 7 else 5
        val builder = NotificationCompat.Builder(ctx, if (silent) VIBRATE_CHANNEL_ID else CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(item.optString("title", "Erinnerung"))
            .setContentText("Beginnt in $mins Minuten")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        // The vibration-only channel has no sound and does vibrate, keeping
        // heads-up behavior possible (setSilent(true) would prevent peeking).
        if (!silent) builder.addAction(android.R.drawable.ic_media_pause, "Ton stoppen", stop)
        return builder.build()
    }

    private fun ensureVibrateChannel(ctx: Context) {
        val manager = ctx.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            VIBRATE_CHANNEL_ID, "Erinnerungen (nur Vibration)", NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Vorwarnungen mit Vibration, ohne Erinnerungs-Weckerton"
            setSound(null, null)
            enableVibration(true)
            setVibrationPattern(longArrayOf(0, 450, 200, 450))
        }
        manager.createNotificationChannel(channel)
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
        if (id < 0 || index < 0 || index >= 32) return
        val entry = ReminderRuntime.find(ctx, id) ?: return
        // Schedule future occurrences before playing, including if the app stays closed.
        try { ReminderRuntime.scheduleOffset(ctx, entry, index) } catch (_: Exception) { }
        if (ReminderRuntime.isVibrateOnly(ctx)) {
            // Vibration-only alarms need no audio foreground service.
            try {
                ctx.getSystemService(NotificationManager::class.java).notify(
                    "fte:$id:$index".hashCode(), ReminderRuntime.notification(ctx, id, index, entry, silent = true)
                )
            } catch (_: SecurityException) { }
            // Android handles vibration via the high-priority silent-sound channel.
            return
        }
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
                manager.notify("fte:$id:$index".hashCode(), ReminderRuntime.notification(ctx, id, index, entry))
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

class NextNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == "de.felix.foto_to_erinnerung.REFRESH_NEXT") {
            ReminderRuntime.updateNextNotification(ctx)
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
        if (item == null || index < 0 || index >= 32 ||
            index >= (item.optJSONArray("minutes") ?: JSONArray("[7,5]")).length()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        if (ReminderRuntime.isVibrateOnly(this)) {
            // State may have changed since the receiver was dispatched.
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val notification = ReminderRuntime.notification(this, id, index, item)
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(990001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
            } else startForeground(990001, notification)
        } catch (_: Exception) { stopSelf(startId); return START_NOT_STICKY }
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify("fte:$id:$index".hashCode(), notification)
        ReminderRuntime.vibrate(this)
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
