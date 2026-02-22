import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ModelService {
  // Use 10.0.2.2 for Android Emulator to access host's localhost.
  // For physical devices, use your computer's LAN IP (e.g., 192.168.x.x).
  static String get _baseUrl {
    if (Platform.isAndroid) {
      // User's specific LAN IP for physical device or emulator access
      return 'http://192.168.18.11:8080';
    }
    return 'http://localhost:8080';
  }

  static const String faceDetectionModelName = 'face-detection';
  static const String faceRecognitionModelName = 'face-recognition';

  Future<bool> ensureModelsDownloaded() async {
    if (kIsWeb) return true; // Web doesn't need downloaded models
    final success1 = await _downloadModel(faceDetectionModelName);
    final success2 = await _downloadModel(faceRecognitionModelName);
    return success1 && success2;
  }

  Future<bool> _downloadModel(String modelName) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(docsDir.path, '$modelName.onnx');
    final file = File(modelPath);

    if (await file.exists()) {
      print('Model $modelName already exists at $modelPath');
      // Ideally check version/hash here
      return true;
    }

    print('Downloading model $modelName...');
    try {
      final response = await http.get(Uri.parse('$_baseUrl/models/$modelName/download'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        print('Model $modelName downloaded successfully to $modelPath');
        return true;
      } else {
        print('Failed to download model $modelName: ${response.statusCode}');
      }
    } catch (e) {
      print('Error downloading model $modelName: $e');
    }
    return false;
  }

  Future<String?> getModelPath(String modelName) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(docsDir.path, '$modelName.onnx');
    if (await File(modelPath).exists()) {
      return modelPath;
    }
    return null;
  }
}
