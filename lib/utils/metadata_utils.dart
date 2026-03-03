import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class MetadataUtils {
  /// Injects GPS coordinates into an image file (JPEG).
  /// Note: This currently involves re-encoding the image to ensure EXIF consistency.
  static Future<Uint8List?> injectGpsMetadata({
    required Uint8List imageBytes,
    required double latitude,
    required double longitude,
  }) async {
    return await compute(_injectGpsIsolate, {
      'bytes': imageBytes,
      'lat': latitude,
      'lng': longitude,
    });
  }

  static Uint8List? _injectGpsIsolate(Map<String, dynamic> params) {
    try {
      final Uint8List bytes = params['bytes'];
      final double lat = params['lat'];
      final double lng = params['lng'];

      // Decode ONLY the EXIF metadata to preserve original image bytes/quality
      img.ExifData exif = img.decodeJpgExif(bytes) ?? img.ExifData();
      
      // Update GPS info using the built-in helper
      // This helper handles the Ref and conversion automatically.
      exif.gpsIfd.setGpsLocation(
        latitude: lat,
        longitude: lng,
      );

      // Inject the modified EXIF back into the original JPEG bytes
      // This is lossless and much faster than decoding/encoding the whole image.
      final result = img.injectJpgExif(bytes, exif);
      return result != null ? Uint8List.fromList(result) : null;
    } catch (e) {
      debugPrint("MetadataUtils: Error injecting GPS: $e");
      return null;
    }
  }
}
