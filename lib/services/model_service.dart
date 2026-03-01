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
  static const String semanticSearchModelName = 'semantic-search';

  static const String _lastCheckKey = 'last_model_update_check';

  Future<bool> ensureModelsDownloaded() async {
    if (kIsWeb) return true; // Web doesn't need downloaded models

    final prefs = await SharedPreferences.getInstance();
    final lastCheckMillis = prefs.getInt(_lastCheckKey) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    // Only check for updates once every 24 hours if files exist
    final bool shouldSkipNetwork = (now - lastCheckMillis) < (24 * 60 * 60 * 1000);
    
    // Check if all models exist locally
    final docsDir = await getApplicationDocumentsDirectory();
    final List<String> modelPaths = [
      p.join(docsDir.path, '$faceDetectionModelName.onnx'),
      p.join(docsDir.path, '$faceRecognitionModelName.onnx'),
      p.join(docsDir.path, '$semanticSearchModelName.onnx'),
    ];
    
    bool allExist = true;
    for (var path in modelPaths) {
      if (!await File(path).exists()) {
        allExist = false;
        break;
      }
    }

    if (shouldSkipNetwork && allExist) {
       debugPrint('ModelService: Skipping network update check (last check < 24h ago).');
       return true;
    }

    // Run all checks in parallel to avoid sequential timeouts
    final results = await Future.wait([
      _downloadModel(faceDetectionModelName),
      _downloadModel(faceRecognitionModelName),
      _downloadModel(semanticSearchModelName),
    ]);
    
    final allSuccess = results.every((success) => success);
    if (allSuccess) {
       await prefs.setInt(_lastCheckKey, now);
    }
    
    return allSuccess;
  }

  Future<bool> _downloadModel(String modelName) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(docsDir.path, '$modelName.onnx');
    final file = File(modelPath);

    final prefs = await SharedPreferences.getInstance();
    final localVersionKey = 'model_version_$modelName';
    final currentLocalVersion = prefs.getString(localVersionKey);

    String? remoteVersion;
    try {
      final response = await http.get(Uri.parse('$_baseUrl/models/$modelName/info'))
          .timeout(const Duration(seconds: 5)); // Reduced to 5s for fast JSON info check (v2)
      
      if (response.statusCode == 200) {
        final info = jsonDecode(response.body);
        remoteVersion = info['version'] as String;
        
        if (await file.exists() && currentLocalVersion == remoteVersion) {
          debugPrint('Model $modelName is up to date (Version: $remoteVersion).');
          return true;
        }
        debugPrint('Model $modelName update available (Local: $currentLocalVersion, Remote: $remoteVersion). Updating...');
      } else {
         if (await file.exists()) {
           debugPrint('Model $modelName: Server returned ${response.statusCode}. Using local fallback.');
           return true; 
         }
      }
    } catch (e) {
      debugPrint('Model $modelName (v2): info check failed or timed out: $e');
      if (await file.exists()) {
        debugPrint('Model $modelName: Using existing local model as fallback.');
        return true;
      }
    }

    print('Downloading model $modelName...');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$_baseUrl/models/$modelName/download'));
      final streamedResponse = await client.send(request).timeout(const Duration(seconds: 300));

      if (streamedResponse.statusCode == 200) {
        // Use a temporary file for atomic write
        final tempFile = File('${file.path}.tmp');
        if (await tempFile.exists()) await tempFile.delete();
        
        final sink = tempFile.openWrite();
        await streamedResponse.stream.pipe(sink);
        await sink.close();
        
        // Atomic rename
        if (await file.exists()) await file.delete();
        await tempFile.rename(file.path);

        if (remoteVersion != null) {
          await prefs.setString(localVersionKey, remoteVersion);
        }
        print('Model $modelName updated successfully to Version: $remoteVersion');
        return true;
      } else {
        print('Failed to download model $modelName: ${streamedResponse.statusCode}');
      }
    } catch (e) {
      print('Error downloading model $modelName: $e');
    } finally {
      client.close();
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
