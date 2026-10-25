package de.felix.foto_to_erinnerung

import android.content.Context
import android.util.Log
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream

/** Phone is the single writer. A full GZIP snapshot also propagates deletions. */
object WearPhoneSync {
    const val PATH = "/fte/reminders"
    private const val TAG = "FteWearSync"
    private val queue = Executors.newSingleThreadExecutor()

    fun publish(ctx: Context, entriesJson: String) {
        val app = ctx.applicationContext
        // R8 & Android must not block Flutter's UI while compressing/sending data.
        queue.execute {
            try {
                val out = ByteArrayOutputStream()
                GZIPOutputStream(out).use { it.write(entriesJson.toByteArray(Charsets.UTF_8)) }
                val bytes = out.toByteArray()
                require(bytes.size < 90_000) {
                    "Zu viele Erinnerungen für ein Wear-DataItem (${bytes.size} Bytes)"
                }
                val p = app.getSharedPreferences("fte_wear_phone", Context.MODE_PRIVATE)
                val generation = p.getLong("generation", 0L) + 1L
                p.edit().putLong("generation", generation).apply()
                val req = PutDataMapRequest.create(PATH).apply {
                    dataMap.putByteArray("gzip", bytes)
                    dataMap.putLong("generation", generation)
                    dataMap.putLong("updatedAt", System.currentTimeMillis())
                }.asPutDataRequest().setUrgent()
                // Wait within the background queue so a later edit cannot be
                // overwritten by an older asynchronous putDataItem completion.
                Tasks.await(Wearable.getDataClient(app).putDataItem(req), 30, TimeUnit.SECONDS)
                Log.i(TAG, "Stand $generation für Wear DataLayer bereitgestellt")
            } catch (e: Exception) {
                Log.e(TAG, "Synchronisierung nicht möglich", e)
            }
        }
    }
}
