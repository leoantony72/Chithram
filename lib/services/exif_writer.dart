import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Calls the native Android [ExifWriterPlugin] to write GPS EXIF tags
/// into MediaStore image files **in-place** — no new file, no deletion,
/// no album changes.
///
/// Use [writeGpsBatch] when tagging multiple photos: all URIs are passed to
/// a single [MediaStore.createWriteRequest] call, so the OS shows exactly
/// ONE "Chithram wants to modify N photos" dialog regardless of how many
/// photos are selected.
class ExifWriter {
  static const _channel = MethodChannel('com.example.ninta/exif_writer');

  /// Writes GPS EXIF to a **single** image. Prefer [writeGpsBatch] for
  /// multi-selection so the system shows only one permission dialog.
  static Future<bool> writeGps({
    required String mediaId,
    required double lat,
    required double lng,
  }) async {
    return writeGpsBatch(mediaIds: [mediaId], lat: lat, lng: lng);
  }

  /// Writes GPS EXIF to **all** images in [mediaIds] using a single native
  /// call. On Android 11+, the OS shows one system dialog:
  ///   "Chithram wants to modify X photos"  [Deny] [Allow]
  /// After the user taps Allow, EXIF is written to every file at once.
  ///
  /// Returns `true` if at least one file was updated, `false` if the user
  /// denied or the write was not possible (caller falls back to cache-only).
  static Future<bool> writeGpsBatch({
    required List<String> mediaIds,
    required double lat,
    required double lng,
  }) async {
    if (kIsWeb || mediaIds.isEmpty) return false;
    try {
      final result = await _channel.invokeMethod<bool>('writeGpsBatch', {
        'mediaIds': mediaIds,
        'lat': lat,
        'lng': lng,
      });
      return result == true;
    } on PlatformException catch (e) {
      debugPrint('ExifWriter batch error: ${e.code} — ${e.message}');
      return false;
    } on MissingPluginException {
      debugPrint('ExifWriter: plugin not available on this platform');
      return false;
    }
  }
}
