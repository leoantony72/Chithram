#ifndef FLUTTER_PLUGIN_FL_TRAINING_PLUGIN_TEMP_PLUGIN_H_
#define FLUTTER_PLUGIN_FL_TRAINING_PLUGIN_TEMP_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace fl_training_plugin_temp {

class FlTrainingPluginTempPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlTrainingPluginTempPlugin();

  virtual ~FlTrainingPluginTempPlugin();

  // Disallow copy and assign.
  FlTrainingPluginTempPlugin(const FlTrainingPluginTempPlugin&) = delete;
  FlTrainingPluginTempPlugin& operator=(const FlTrainingPluginTempPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace fl_training_plugin_temp

#endif  // FLUTTER_PLUGIN_FL_TRAINING_PLUGIN_TEMP_PLUGIN_H_
