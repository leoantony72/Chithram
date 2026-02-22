import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FlTrainingPlugin {
  static const MethodChannel _channel = MethodChannel('fl_training');

  static Future<String?> get platformVersion async {
    final String? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  static Future<String> train(String modelPath, int epochs, int batchSize) async {
    try {
      final String result = await _channel.invokeMethod('train', {
        'modelPath': modelPath,
        'epochs': epochs,
        'batchSize': batchSize,
      });
      return result;
    } on PlatformException catch (e) {
      debugPrint("Failed to train model: '${e.message}'.");
      rethrow;
    }
  }
}
