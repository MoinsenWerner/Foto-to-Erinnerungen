package de.felix.foto_to_erinnerung

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.net.Uri
import android.util.Log
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.DataMapItem
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.time.temporal.TemporalAdjusters
import java.util.Locale
import java.util.zip.GZIPInputStream
import kotlin.math.max

private const val DATA_PATH = "/fte/reminders"
private const val CHANNEL = "fte_watch_v1"
private const val REFRESH = "de.felix.foto_to_erinnerung.WATCH_REFRESH"
private const val LOG = "FteWatch"

/** Exact same repeat rules as the phone's native alarm scheduler. */
private object WatchLogic {
    fun next(item: JSONObject, cutoff: ZonedDateTime): ZonedDateTime? {
        val anchor = try { LocalDateTime.parse(item.getString("start")) } catch (_: Exception) { return null }
        val zone = ZoneId.systemDefault()
        val base = anchor.atZone(zone)
        if (!item.optBoolean("repeat", false)) return if (base.isAfter(cutoff)) base else null
        val every = max(1, item.optInt("every", 1))
        val selected = mutableSetOf<Int>()
        val weekdays = item.optJSONArray("weekdays")
        if (weekdays != null) for (i in 0 until weekdays.length()) selected.add(weekdays.optInt(i))
        when (item.optString("unit", "days")) {
            "hours" -> {
                val hours = max(0L, ChronoUnit.HOURS.between(base.toInstant(), cutoff.toInstant()))
                var step = max(0L, hours / every - 1L)
                repeat(3000) {
                    val date = base.plusHours(step * every.toLong())
                    if (date.isAfter(cutoff) && (selected.isEmpty() || date.dayOfWeek.value in selected)) return date
                    step++
                }
            }
            "weeks" -> {
                val monday = anchor.toLocalDate().with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
                val weeks = max(0L, ChronoUnit.WEEKS.between(monday, cutoff.toLocalDate()))
                var block = max(0L, weeks / every - 1L)
                val days = if (selected.isEmpty()) listOf(anchor.dayOfWeek.value) else selected.sorted()
                repeat(100) {
                    val week = monday.plusWeeks(block * every.toLong())
                    for (day in days) {
                        if (day !in 1..7) continue
                        val date = LocalDateTime.of(week.plusDays((day - 1).toLong()), anchor.toLocalTime()).atZone(zone)
                        if (!date.isBefore(base) && date.isAfter(cutoff)) return date
                    }
                    block++
                }
            }
            else -> {
                val days = max(0L, ChronoUnit.DAYS.between(anchor.toLocalDate(), cutoff.toLocalDate()))
                var step = max(0L, days / every - 1L)
                repeat(1000) {
                    val date = anchor.plusDays(step * every.toLong()).atZone(zone)
                    if (date.isAfter(cutoff) && (selected.isEmpty() || date.dayOfWeek.value in selected)) return date
                    step++
                }
            }
        }
        return null
    }

    fun upcoming(entries: JSONArray, count: Int = 60): List<Pair<ZonedDateTime, JSONObject>> {
        val now = ZonedDateTime.now().minusNanos(1)
        val until = now.plusDays(30)
        val output = mutableListOf<Pair<ZonedDateTime, JSONObject>>()
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            var cursor = now
            // Cap each definition to avoid excessive UI work for hourly repeating items.
            for (n in 0 until 40) {
                val at = next(item, cursor) ?: break
                if (at.isAfter(until)) break
                output.add(at to item)
                if (!item.optBoolean("repeat", false)) break
                cursor = at.plusNanos(1)
            }
        }
        return output.sortedBy { it.first.toInstant() }.take(count)
    }
}

/** Watch stores its own durable copy; DataLayer is transport, not persistence. */
private object WatchStore {
    private const val STORE = "fte_watch_state"
    private const val KEY_DATA = "entries"
    private const val KEY_DATE = "sync_time"
    fun items(ctx: Context): JSONArray = try {
        JSONArray(ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE).getString(KEY_DATA, "[]"))
    } catch (_: Exception) { JSONArray() }
    fun syncTime(ctx: Context): Long = ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE).getLong(KEY_DATE, 0)

    @Synchronized
    fun accept(ctx: Context, data: com.google.android.gms.wearable.DataItem) {
        if (data.uri.path != DATA_PATH) return
        try {
            val map = DataMapItem.fromDataItem(data).dataMap
            val gzip = map.getByteArray("gzip") ?: return
            require(gzip.size < 100_000) { "Wear-Nachricht zu groß" }
            val plain = GZIPInputStream(ByteArrayInputStream(gzip)).use { stream ->
                // Defensive bound against invalid compressed payloads.
                val buffer = ByteArray(8192)
                val result = ByteArrayOutputStream()
                while (true) {
                    val n = stream.read(buffer)
                    if (n == -1) break
                    require(result.size() + n <= 2_000_000) { "Datenmenge überschritten" }
                    result.write(buffer, 0, n)
                }
                result.toString("UTF-8")
            }
            val list = JSONArray(plain)
            // Cancel outdated alarms before replacing the persistent snapshot.
            WatchAlarms.cancel(ctx, items(ctx))
            ctx.getSharedPreferences(STORE, Context.MODE_PRIVATE).edit()
                .putString(KEY_DATA, list.toString())
                .putLong(KEY_DATE, System.currentTimeMillis())
                .commit()
            WatchAlarms.schedule(ctx)
            ctx.sendBroadcast(Intent(REFRESH).setPackage(ctx.packageName))
            Log.i(LOG, "Synchronisiert: ${list.length()} Erinnerungen")
        } catch (e: Exception) { Log.e(LOG, "Fehler beim Übernehmen", e) }
    }
}

/** Background listener receives phone changes, even when watch UI is closed. */
class WatchDataListener : WearableListenerService() {
    override fun onDataChanged(events: DataEventBuffer) {
        for (event in events) {
            if (event.type == DataEvent.TYPE_CHANGED && event.dataItem.uri.path == DATA_PATH) {
                WatchStore.accept(this, event.dataItem)
            }
        }
    }
}

private object WatchAlarms {
    private fun id(reminder: Int, index: Int): Int = "wear:$reminder:$index".hashCode()
    private fun manager(ctx: Context) = ctx.getSystemService(AlarmManager::class.java)
    private fun pending(ctx: Context, reminder: Int, index: Int, create: Boolean): PendingIntent? {
        val intent = Intent(ctx, WatchAlarmReceiver::class.java).apply {
            action = "de.felix.foto_to_erinnerung.WATCH_ALARM"
            putExtra("id", reminder)
            putExtra("index", index)
        }
        val flags = PendingIntent.FLAG_IMMUTABLE or
            (if (create) PendingIntent.FLAG_UPDATE_CURRENT else PendingIntent.FLAG_NO_CREATE)
        return PendingIntent.getBroadcast(ctx, id(reminder, index), intent, flags)
    }
    fun cancel(ctx: Context, entries: JSONArray) {
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            for (j in 0 until 32) {
                val intent = pending(ctx, item.optInt("id"), j, false) ?: continue
                manager(ctx).cancel(intent)
                intent.cancel()
            }
        }
    }
    fun schedule(ctx: Context) {
        val entries = WatchStore.items(ctx)
        val now = ZonedDateTime.now()
        for (i in 0 until entries.length()) {
            val item = entries.optJSONObject(i) ?: continue
            val offsets = item.optJSONArray("minutes") ?: JSONArray("[7,5]")
            for (j in 0 until minOf(32, offsets.length())) {
                val minutes = offsets.optInt(j, 5)
                if (minutes !in 0..525600) continue
                // Find the next reminder whose pre-warning has not yet passed.
                val at = WatchLogic.next(item, now.plusMinutes(minutes.toLong()).plusSeconds(1)) ?: continue
                val trigger = at.minusMinutes(minutes.toLong()).toInstant().toEpochMilli()
                val pi = pending(ctx, item.optInt("id"), j, true) ?: continue
                try {
                    if (Build.VERSION.SDK_INT < 31 || manager(ctx).canScheduleExactAlarms())
                        manager(ctx).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                    else manager(ctx).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                } catch (e: SecurityException) {
                    manager(ctx).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pi)
                }
            }
        }
    }
    fun notify(ctx: Context, item: JSONObject, offset: Int) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL, "Erinnerungen", NotificationManager.IMPORTANCE_HIGH).apply {
            enableVibration(true)
            vibrationPattern = longArrayOf(0, 250, 120, 250)
            setSound(null, null) // Watch vibrations only; phone handles user MP3/system tone.
        }
        nm.createNotificationChannel(channel)
        val open = PendingIntent.getActivity(ctx, 5,
            Intent(ctx, WatchActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(ctx, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(item.optString("title", "Erinnerung"))
            .setContentText("Beginnt in $offset Minuten")
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .build()
        try { nm.notify((System.currentTimeMillis() % Int.MAX_VALUE).toInt(), notification) }
        catch (_: SecurityException) { Log.w(LOG, "Benachrichtigungsberechtigung fehlt") }
    }
}

class WatchAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra("id", -1)
        val index = intent.getIntExtra("index", -1)
        val all = WatchStore.items(ctx)
        for (i in 0 until all.length()) {
            val item = all.optJSONObject(i) ?: continue
            if (item.optInt("id") != id) continue
            val offsets = item.optJSONArray("minutes") ?: JSONArray("[7,5]")
            if (index in 0 until offsets.length()) WatchAlarms.notify(ctx, item, offsets.optInt(index))
            break
        }
        // Re-arm recurring reminders; one-time reminders no longer qualify.
        WatchAlarms.schedule(ctx)
    }
}

class WatchBootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED ||
            intent.action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            intent.action == Intent.ACTION_TIME_CHANGED ||
            intent.action == Intent.ACTION_TIMEZONE_CHANGED ||
            intent.action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED) {
            WatchAlarms.schedule(ctx)
        }
    }
}

class WatchActivity : Activity() {
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) { render() }
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 771)
        }
        fetchCurrentSnapshot()
        render()
    }
    override fun onStart() {
        super.onStart()
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, IntentFilter(REFRESH), Context.RECEIVER_NOT_EXPORTED)
        else {
            @Suppress("DEPRECATION")
            registerReceiver(receiver, IntentFilter(REFRESH))
        }
    }
    override fun onStop() { unregisterReceiver(receiver); super.onStop() }
    override fun onResume() { super.onResume(); render() }

    private fun fetchCurrentSnapshot() {
        val uri = Uri.parse("wear://*/fte/reminders")
        Wearable.getDataClient(this).getDataItems(uri, DataClient.FILTER_LITERAL)
            .addOnSuccessListener { buffer ->
                try { for (item in buffer) if (item.uri.path == DATA_PATH) WatchStore.accept(this, item) }
                finally { buffer.release() }
            }.addOnFailureListener { Log.w(LOG, "Keine Verbindung zum Handy", it) }
    }
    private fun render() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.BLACK)
            setPadding(22, 12, 22, 20)
        }
        fun label(value: String, size: Float, color: Int, padding: Int = 8) {
            root.addView(TextView(this).apply {
                text = value
                textSize = size
                setTextColor(color)
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(0, padding, 0, padding)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        label("Erinnerungen", 18f, Color.WHITE)
        val last = WatchStore.syncTime(this)
        val stamp = if (last == 0L) "Noch nicht synchronisiert" else {
            val date = java.time.Instant.ofEpochMilli(last).atZone(ZoneId.systemDefault())
            "Sync: " + date.format(DateTimeFormatter.ofPattern("dd.MM. HH:mm", Locale.GERMAN))
        }
        label(stamp, 11f, Color.LTGRAY, 2)
        val next = WatchLogic.upcoming(WatchStore.items(this))
        if (next.isEmpty()) label("Keine anstehenden Erinnerungen. Handy-App öffnen und synchronisieren.", 12f, Color.LTGRAY)
        var day = ""
        for ((date, item) in next) {
            val current = date.format(DateTimeFormatter.ofPattern("EEE, dd.MM.yyyy", Locale.GERMAN))
            if (current != day) { day = current; label(current, 13f, Color.CYAN, 12) }
            val time = date.format(DateTimeFormatter.ofPattern("HH:mm", Locale.GERMAN))
            label("$time  ${item.optString("title", "Erinnerung")}", 13f, Color.WHITE, 3)
        }
        val refresh = Button(this).apply {
            text = "Synchronisieren"
            setOnClickListener { fetchCurrentSnapshot() }
        }
        root.addView(refresh)
        if (Build.VERSION.SDK_INT >= 31 && !getSystemService(AlarmManager::class.java).canScheduleExactAlarms()) {
            root.addView(Button(this).apply {
                text = "Genaue Alarme erlauben"
                setOnClickListener {
                    startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                        data = Uri.parse("package:$packageName")
                    })
                }
            })
        }
        val scroll = ScrollView(this).apply { isFillViewport = false; addView(root) }
        setContentView(scroll)
    }
}
