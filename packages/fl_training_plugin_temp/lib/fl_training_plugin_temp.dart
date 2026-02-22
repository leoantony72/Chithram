
import 'fl_training_plugin_temp_platform_interface.dart';

class FlTrainingPluginTemp {
  Future<String?> getPlatformVersion() {
    return FlTrainingPluginTempPlatform.instance.getPlatformVersion();
  }
}
