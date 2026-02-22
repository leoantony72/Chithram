#include "include/fl_training_plugin_temp/fl_training_plugin_temp_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "fl_training_plugin_temp_plugin.h"

void FlTrainingPluginTempPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  fl_training_plugin_temp::FlTrainingPluginTempPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
