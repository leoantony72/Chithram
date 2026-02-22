import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'fl_training_plugin_temp_platform_interface.dart';

/// An implementation of [FlTrainingPluginTempPlatform] that uses method channels.
class MethodChannelFlTrainingPluginTemp extends FlTrainingPluginTempPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('fl_training_plugin_temp');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }
}
