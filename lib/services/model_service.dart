import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class ModelService {
  // Update with your backend URL. Use 10.0.2.2 for Android Emulator to access localhost
  static const String _baseUrl = 'http://10.0.2.2:8080';
  // static const String _baseUrl = 'http://localhost:8080'; // For iOS Simulator

  static const String faceDetectionModelName = 'face-detection';
  static const String faceRecognitionModelName = 'face-recognition';

  Future<void> ensureModelsDownloaded() async {
    await _downloadModel(faceDetectionModelName);
    await _downloadModel(faceRecognitionModelName);
  }

  Future<void> _downloadModel(String modelName) async {
    final docsDir = await getApplicationDocumentsDirectory();
    final modelPath = p.join(docsDir.path, '$modelName.onnx');
    final file = File(modelPath);

    if (await file.exists()) {
      print('Model $modelName already exists at $modelPath');
      // Ideally check version/hash here
      return;
    }

    print('Downloading model $modelName...');
    try {
      final response = await http.get(Uri.parse('$_baseUrl/models/$modelName/download'));

      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        print('Model $modelName downloaded successfully to $modelPath');
      } else {
        print('Failed to download model $modelName: ${response.statusCode}');
      }
    } catch (e) {
      print('Error downloading model $modelName: $e');
    }
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
