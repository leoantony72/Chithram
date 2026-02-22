import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'fl_training_plugin_temp_method_channel.dart';

abstract class FlTrainingPluginTempPlatform extends PlatformInterface {
  /// Constructs a FlTrainingPluginTempPlatform.
  FlTrainingPluginTempPlatform() : super(token: _token);

  static final Object _token = Object();

  static FlTrainingPluginTempPlatform _instance = MethodChannelFlTrainingPluginTemp();

  /// The default instance of [FlTrainingPluginTempPlatform] to use.
  ///
  /// Defaults to [MethodChannelFlTrainingPluginTemp].
  static FlTrainingPluginTempPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [FlTrainingPluginTempPlatform] when
  /// they register themselves.
  static set instance(FlTrainingPluginTempPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
