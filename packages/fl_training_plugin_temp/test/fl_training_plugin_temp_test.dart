import 'package:flutter_test/flutter_test.dart';
import 'package:fl_training_plugin_temp/fl_training_plugin_temp.dart';
import 'package:fl_training_plugin_temp/fl_training_plugin_temp_platform_interface.dart';
import 'package:fl_training_plugin_temp/fl_training_plugin_temp_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class MockFlTrainingPluginTempPlatform
    with MockPlatformInterfaceMixin
    implements FlTrainingPluginTempPlatform {

  @override
  Future<String?> getPlatformVersion() => Future.value('42');
}

void main() {
  final FlTrainingPluginTempPlatform initialPlatform = FlTrainingPluginTempPlatform.instance;

  test('$MethodChannelFlTrainingPluginTemp is the default instance', () {
    expect(initialPlatform, isInstanceOf<MethodChannelFlTrainingPluginTemp>());
  });

  test('getPlatformVersion', () async {
    FlTrainingPluginTemp flTrainingPluginTempPlugin = FlTrainingPluginTemp();
    MockFlTrainingPluginTempPlatform fakePlatform = MockFlTrainingPluginTempPlatform();
    FlTrainingPluginTempPlatform.instance = fakePlatform;

    expect(await flTrainingPluginTempPlugin.getPlatformVersion(), '42');
  });
}
