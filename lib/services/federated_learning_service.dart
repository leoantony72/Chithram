import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:fl_training_plugin/fl_training_plugin.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import 'auth_service.dart';
import 'backup_service.dart';
import 'crypto_service.dart';
import 'database_service.dart';
import 'model_service.dart';
import 'api_config.dart';

class FederatedLearningService {
  static String get serverUrl => ApiConfig().baseUrl;
  static const String globalModelFilename = "face-detection.onnx";
  static const String lastUpdatedKey = "fl_last_updated";

  final ModelService _modelService = ModelService();

  Future<void> init() async {
    await _modelService.ensureModelsDownloaded();
  }

  Future<void> _downloadGlobalModel() async {
    await _modelService.ensureModelsDownloaded();
  }



  Future<void> trainAndUpload({void Function(double progress, String status)? onProgress}) async {
    onProgress?.call(0, "Checking for latest model...");
    await _downloadGlobalModel();
    
    final appDir = await getApplicationDocumentsDirectory();
    final modelFile = File('${appDir.path}/$globalModelFilename');
    
    if (!await modelFile.exists()) {
      onProgress?.call(0, "No base model found.");
      return;
    }

    final updatedModelPath = "${modelFile.path}_update.pth";
    final updatedFile = File(updatedModelPath);

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      onProgress?.call(0, "Preparing Training Data...");
      
      final trainCacheDir = Directory('${appDir.path}/train_cache');
      if (await trainCacheDir.exists()) await trainCacheDir.delete(recursive: true);
      await trainCacheDir.create();

        try {
          final untreatedFaces = await DatabaseService().getUntrainedFaces(limit: 40);
          final totalUntrainedCount = await DatabaseService().getTotalUntrainedCount();
          
          if (untreatedFaces.isNotEmpty) {
             final firstId = untreatedFaces.first['id'];
             final lastId = untreatedFaces.last['id'];
             debugPrint("Selected ${untreatedFaces.length} faces (IDs: $firstId to $lastId) from $totalUntrainedCount total pending.");
             onProgress?.call(0, "Training Batch (Remaining: $totalUntrainedCount)...");
          }

          if (untreatedFaces.isEmpty) {
            onProgress?.call(1.0, "All available local data already processed.");
            return;
          }

        final session = await AuthService().loadSession();
        if (session == null) {
          onProgress?.call(0, "Auth session required.");
          return;
        }
        final userId = session['username'] as String;
        final masterKeyBytes = session['masterKey'] as Uint8List;
        final masterKey = SecureKey.fromList(CryptoService().sodium, masterKeyBytes);

        final Set<String> downloadedIds = {};
        for (int i = 0; i < untreatedFaces.length; i++) {
          final face = untreatedFaces[i];
          final path = face['image_path'] as String;
          if (path.startsWith('cloud_')) {
            final imageId = path.substring(6).trim();
            if (downloadedIds.contains(imageId)) continue;
            
            onProgress?.call(i / untreatedFaces.length * 0.2, "Decrypting images...");
            downloadedIds.add(imageId);
            
            final remote = await BackupService().fetchSingleRemoteImage(userId, imageId);
            if (remote != null) {
              final bytes = await BackupService().fetchAndDecryptFromUrl(remote.originalUrl, masterKey);
              if (bytes != null) {
                 await File('${trainCacheDir.path}/$imageId.jpg').writeAsBytes(bytes);
              }
            }
          }
        }

        final dbPathStr = await getDatabasesPath();
        final sqliteDbPath = join(dbPathStr, 'chithram_faces.db');

        onProgress?.call(0.2, "Starting AI Engine...");
        final String pythonCmd = !kIsWeb && Platform.isWindows ? '.venv\\Scripts\\python.exe' : 'python';
        final process = await Process.start(pythonCmd, [
          'scripts/desktop_train.py',
          modelFile.path,
          updatedModelPath,
          sqliteDbPath,
          trainCacheDir.path,
        ]);
        
        process.stdout.transform(SystemEncoding().decoder).listen((data) {
          final lines = data.split('\n');
          for (var line in lines) {
            line = line.trim();
            if (line.startsWith("PROGRESS: ")) {
              try {
                final parts = line.substring(10).split('/');
                final current = double.parse(parts[0]);
                final total = double.parse(parts[1]);
                // Scale progress to 20% - 90% range
                onProgress?.call(0.2 + (current / total * 0.7), "Training AI Model...");
              } catch (_) {}
            } else if (line.startsWith("STATUS: ")) {
              onProgress?.call(-1, line.substring(8)); // -1 means keep current progress
            }
            debugPrint(line);
          }
        });
        
        process.stderr.transform(SystemEncoding().decoder).listen((data) {
           debugPrint("Python Error: ${data.trim()}");
        });
        
        final exitCode = await process.exitCode;
        if (await trainCacheDir.exists()) await trainCacheDir.delete(recursive: true);

        if (exitCode == 0) {
           // Mark faces as trained in local DB to ensure persistence
           final db = await DatabaseService().database;
           for (final face in untreatedFaces) {
             final id = face['id'];
             await db.update('faces', {'fl_trained': 1}, where: 'id = ?', whereArgs: [id]);
           }
           debugPrint("Marked ${untreatedFaces.length} faces as trained in Dart.");
           
           // PROACTIVE: Sync this training status to the cloud database immediately
           onProgress?.call(0.95, "Syncing training status to cloud...");
           try {
             await BackupService().uploadFaceDatabase();
             debugPrint("Face database synced to cloud after training.");
           } catch (e) {
             debugPrint("Failed to sync face database after training: $e");
           }
        } else if (exitCode == 3) { // Exit code 3 is our "Already Trained" signal
           onProgress?.call(1.0, "All data already processed.");
           return;
        } else if (exitCode != 0) { 
           onProgress?.call(0, "Training process failed (Exit: $exitCode)");
           return;
        }

        onProgress?.call(0.9, "Uploading local improvements...");
      } catch (e) {
        onProgress?.call(0, "Training failed: $e");
        return;
      }
    } else {
      onProgress?.call(0.5, "Mobile training started...");
      try {
        await FlTrainingPlugin.train(modelFile.path, 1, 32); 
        onProgress?.call(0.9, "Training completed. Uploading...");
      } catch (e) {
        onProgress?.call(0, "Mobile training failed: $e");
        return;
      }
    }

    if (!await updatedFile.exists()) {
       onProgress?.call(0, "Update file generation failed.");
       return;
    }
    
    // 4. Upload Update
    try {
      var request = http.MultipartRequest('POST', Uri.parse('$serverUrl/fl/update'));
      request.files.add(
        await http.MultipartFile.fromPath(
          'model', 
          updatedFile.path,
          filename: 'local_update.pth',
        ),
      );
      
      var res = await request.send();
      if (res.statusCode == 200) {
        onProgress?.call(1.0, "Success! Model improved and uploaded.");
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(lastUpdatedKey, DateTime.now().millisecondsSinceEpoch);
      } else {
        onProgress?.call(0, "Upload failed: ${res.statusCode}");
      }
    } catch (e) {
      onProgress?.call(0, "Upload error: $e");
    }
  }
}
