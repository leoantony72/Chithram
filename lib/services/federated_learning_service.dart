import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:fl_training_plugin/fl_training_plugin.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class FederatedLearningService {
  static String get serverUrl {
    if (kIsWeb) return 'http://localhost:8080';
    if (Platform.isAndroid || Platform.isIOS) {
      return 'http://192.168.1.5:8080'; // Replace with actual server IP
    }
    return 'http://localhost:8080';
  }
  static const String globalModelFilename = "face-detection.onnx";
  static const String lastUpdatedKey = "fl_last_updated";

  Future<void> init() async {
    // Check if we need to download the initial global model
    final appDir = await getApplicationDocumentsDirectory();
    final modelFile = File('${appDir.path}/$globalModelFilename');
    
    if (!await modelFile.exists()) {
      await _downloadGlobalModel();
    }
  }

  Future<void> _downloadGlobalModel() async {
    try {
      final response = await http.get(Uri.parse('$serverUrl/fl/global'));
      if (response.statusCode == 200) {
        final appDir = await getApplicationDocumentsDirectory();
        final file = File('${appDir.path}/$globalModelFilename');
        await file.writeAsBytes(response.bodyBytes);
        debugPrint("Downloaded global model to ${file.path}");
      } else {
        debugPrint("Failed to download global model: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("Error downloading global model: $e");
    }
  }



  Future<void> trainAndUpload() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelFile = File('${appDir.path}/$globalModelFilename');
    
    if (!await modelFile.exists()) {
      debugPrint("No base model to train on.");
      return;
    }

    // 3. Define output path for the locally trained model update
    // The trainer will save the weights to <modelPath>_updated.onnx
    final updatedModelPath = "${modelFile.path}_updated.onnx";
    final updatedFile = File(updatedModelPath);

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      debugPrint("Starting Active Desktop Federated Learning training via Local Python child process...");
      try {
        final dbPathStr = await getDatabasesPath();
        final sqliteDbPath = join(dbPathStr, 'chithram_faces.db');

        final String pythonCmd = !kIsWeb && Platform.isWindows ? '.venv\\Scripts\\python.exe' : 'python';
        final process = await Process.start(pythonCmd, [
          'scripts/desktop_train.py',
          modelFile.path,
          updatedModelPath,
          sqliteDbPath,
        ]);
        
        // Stream the machine learning training progress live to the Flutter console
        process.stdout.transform(SystemEncoding().decoder).listen((data) {
          debugPrint(data.trim());
        });
        
        process.stderr.transform(SystemEncoding().decoder).listen((data) {
          debugPrint("Python Error/Warning: ${data.trim()}");
        });
        
        final exitCode = await process.exitCode;
        if (exitCode != 0) {
          debugPrint("Failed to complete desktop python training. Exit code: $exitCode");
          return;
        }

        debugPrint("Desktop Training block finished successfully.");
      } catch (e) {
        debugPrint("Failed to launch desktop python training: $e");
        return;
      }
    } else {
      debugPrint("Starting active local training via PyTorch Mobile plugin...");
      try {
        // Execute Training using Native Plugin for Mobile edge
        await FlTrainingPlugin.train(modelFile.path, 1, 32); 
        debugPrint("Training completed.");
      } catch (e) {
        debugPrint("Mobile training failed: $e");
        return;
      }
    }

    if (!await updatedFile.exists()) {
       debugPrint("Updated model file not found at $updatedModelPath");
       return;
    }
    
    // 4. Upload Update
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$serverUrl/fl/update'));
      request.files.add(
        await http.MultipartFile.fromPath(
          'model', 
          updatedFile.path,
          filename: 'local_update.onnx',
        ),
      );
      
      var res = await request.send();
      if (res.statusCode == 200) {
        debugPrint("Uploaded local update successfully.");
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(lastUpdatedKey, DateTime.now().millisecondsSinceEpoch);
        
        // Cleanup?
        // await updatedFile.delete();
      } else {
        debugPrint("Failed to upload update: ${res.statusCode}");
      }
    } catch (e) {
      debugPrint("Error uploading update: $e");
    }
  }
}
