import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_config.dart';

class ModelService {
  // Base URL is dynamically managed
  static String get _baseUrl => ApiConfig().baseUrl;

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

    final prefs = await SharedPreferences.getInstance();
    final localVersionKey = 'model_version_$modelName';
    final currentLocalVersion = prefs.getString(localVersionKey);

    String? remoteVersion;
    final response = await http.get(Uri.parse('$_baseUrl/models/$modelName/info'))
        .timeout(const Duration(seconds: 10));
    
    if (response.statusCode == 200) {
      final info = jsonDecode(response.body);
      remoteVersion = info['version'] as String;
      
      if (await file.exists() && currentLocalVersion == remoteVersion) {
        print('Model $modelName is up to date (Version: $remoteVersion).');
        return true;
      }
      print('Model $modelName update available (Local: $currentLocalVersion, Remote: $remoteVersion). Updating...');
    } else {
       if (await file.exists()) return true; // Fallback to local if server is down
    }

    print('Downloading model $modelName...');
    try {
      final downloadResponse = await http.get(Uri.parse('$_baseUrl/models/$modelName/download'))
          .timeout(const Duration(seconds: 30));

      if (downloadResponse.statusCode == 200) {
        await file.writeAsBytes(downloadResponse.bodyBytes);
        if (remoteVersion != null) {
          await prefs.setString(localVersionKey, remoteVersion);
        }
        print('Model $modelName updated successfully to Version: $remoteVersion');
        return true;
      } else {
        print('Failed to download model $modelName: ${downloadResponse.statusCode}');
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
