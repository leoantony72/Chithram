package com.example.ninta

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import kotlin.math.abs

/**
 * ExifWriterPlugin
 *
 * Writes GPS EXIF into MediaStore image files IN-PLACE with no copy/delete.
 *
 * Supports batch writes: a single MediaStore.createWriteRequest() call covers
 * ALL selected photos at once — the user sees exactly ONE system dialog
 * "Chithram wants to modify N photos" regardless of how many are selected.
 *
 * Strategy by Android version:
 *  - Android ≤ 10 (API 29):  requestLegacyExternalStorage allows direct
 *    openFileDescriptor("rw") without a system dialog.
 *  - Android 11+ (API 30+): MediaStore.createWriteRequest() with ALL URIs
 *    bundled into one call → one dialog → write all on approval.
 */
class ExifWriterPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "com.example.ninta/exif_writer"
        private const val WRITE_REQUEST_CODE = 7001
    }

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: Activity? = null

    // State held across the async system-dialog round-trip
    private var pendingResult: Result? = null
    private var pendingMediaIds: List<String> = emptyList()
    private var pendingLat: Double = 0.0
    private var pendingLng: Double = 0.0

    // ── FlutterPlugin ────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    // ── ActivityAware ────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() { activity = null }

    // ── ActivityResultListener ───────────────────────────────────────────────

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != WRITE_REQUEST_CODE) return false

        val pr = pendingResult ?: return true
        pendingResult = null

        if (resultCode == Activity.RESULT_OK) {
            // User approved — write GPS EXIF to every file in the batch
            val written = pendingMediaIds.count { mediaId ->
                writeGpsViaFileDescriptor(mediaId, pendingLat, pendingLng)
            }
            pr.success(written > 0)
        } else {
            pr.success(false)
        }
        return true
    }

    // ── MethodCallHandler ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            // Single write (legacy — kept for compatibility)
            "writeGps" -> {
                val mediaId = call.argument<String>("mediaId") ?: run {
                    result.error("INVALID_ARGS", "mediaId required", null); return
                }
                val lat = call.argument<Double>("lat") ?: run {
                    result.error("INVALID_ARGS", "lat required", null); return
                }
                val lng = call.argument<Double>("lng") ?: run {
                    result.error("INVALID_ARGS", "lng required", null); return
                }
                handleBatchWrite(listOf(mediaId), lat, lng, result)
            }

            // Batch write — single dialog for all photos
            "writeGpsBatch" -> {
                val mediaIds = call.argument<List<String>>("mediaIds") ?: run {
                    result.error("INVALID_ARGS", "mediaIds required", null); return
                }
                val lat = call.argument<Double>("lat") ?: run {
                    result.error("INVALID_ARGS", "lat required", null); return
                }
                val lng = call.argument<Double>("lng") ?: run {
                    result.error("INVALID_ARGS", "lng required", null); return
                }
                handleBatchWrite(mediaIds, lat, lng, result)
            }

            else -> result.notImplemented()
        }
    }

    // ── Core Logic ───────────────────────────────────────────────────────────

    private fun handleBatchWrite(
        mediaIds: List<String>,
        lat: Double,
        lng: Double,
        result: Result
    ) {
        if (mediaIds.isEmpty()) { result.success(false); return }

        // 1. Try direct write for every file (works on Android ≤ 10)
        val failedIds = mediaIds.filter { id ->
            !writeGpsViaFileDescriptor(id, lat, lng)
        }

        if (failedIds.isEmpty()) {
            // All succeeded without a dialog
            result.success(true)
            return
        }

        // 2. Android 11+: one createWriteRequest with ALL failing URIs together
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val act = activity ?: run { result.success(false); return }

            val uris = failedIds.mapNotNull { buildUri(it) }
            if (uris.isEmpty()) { result.success(false); return }

            try {
                val pendingIntent = MediaStore.createWriteRequest(
                    context.contentResolver,
                    uris   // <── ALL photos in one request → ONE dialog
                )

                pendingResult   = result
                pendingMediaIds = failedIds
                pendingLat      = lat
                pendingLng      = lng

                act.startIntentSenderForResult(
                    pendingIntent.intentSender,
                    WRITE_REQUEST_CODE,
                    null, 0, 0, 0
                )
                // Resolved asynchronously in onActivityResult()
            } catch (e: Exception) {
                pendingResult = null
                result.success(false)
            }
        } else {
            // Android < 11 and direct write failed — nothing more we can do
            result.success(false)
        }
    }

    private fun writeGpsViaFileDescriptor(mediaId: String, lat: Double, lng: Double): Boolean {
        val uri = buildUri(mediaId) ?: return false
        val pfd = try {
            context.contentResolver.openFileDescriptor(uri, "rw")
        } catch (e: SecurityException) {
            return false
        } catch (e: Exception) {
            return false
        } ?: return false

        return pfd.use { descriptor ->
            try {
                val exif = ExifInterface(descriptor.fileDescriptor)
                exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE,     decimalToDms(abs(lat)))
                exif.setAttribute(ExifInterface.TAG_GPS_LATITUDE_REF,  if (lat >= 0) "N" else "S")
                exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE,    decimalToDms(abs(lng)))
                exif.setAttribute(ExifInterface.TAG_GPS_LONGITUDE_REF, if (lng >= 0) "E" else "W")
                exif.saveAttributes()
                true
            } catch (e: Exception) {
                false
            }
        }
    }

    private fun buildUri(mediaId: String): Uri? = try {
        ContentUris.withAppendedId(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            mediaId.toLong()
        )
    } catch (e: NumberFormatException) {
        null
    }

    private fun decimalToDms(decimal: Double): String {
        val degrees = decimal.toInt()
        val minutesFloat = (decimal - degrees) * 60.0
        val minutes = minutesFloat.toInt()
        val secondsRational = Math.round((minutesFloat - minutes) * 60.0 * 1000).toInt()
        return "$degrees/1,$minutes/1,$secondsRational/1000"
    }
}
