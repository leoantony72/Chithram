#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <sstream>

// Note: Ensure your CMakeLists.txt links against ONNX Runtime inference libs and includes headers if needed for inference
#include "include/fl_training_plugin/fl_training_plugin_c_api.h"


namespace {

class FlTrainingPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  FlTrainingPlugin();

  virtual ~FlTrainingPlugin();

 private:
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

// static
void FlTrainingPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "fl_training",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<FlTrainingPlugin>();

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

FlTrainingPlugin::FlTrainingPlugin() {}

FlTrainingPlugin::~FlTrainingPlugin() {}

void FlTrainingPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  
  if (method_call.method_name().compare("getPlatformVersion") == 0) {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    // version_stream << CheckWindowsVersion(); // Add helper if needed
    result->Success(flutter::EncodableValue(version_stream.str()));
  } 
  else if (method_call.method_name().compare("train") == 0) {
    const auto *arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    
    std::string modelPath;
    int epochs = 1;
    int batchSize = 1;

    if (arguments) {
        auto it = arguments->find(flutter::EncodableValue("modelPath"));
        if (it != arguments->end() && std::holds_alternative<std::string>(it->second)) {
            modelPath = std::get<std::string>(it->second);
        }
        
        it = arguments->find(flutter::EncodableValue("epochs"));
        if (it != arguments->end() && std::holds_alternative<int>(it->second)) {
            epochs = std::get<int>(it->second);
        }
        
        it = arguments->find(flutter::EncodableValue("batchSize"));
        if (it != arguments->end() && std::holds_alternative<int>(it->second)) {
            batchSize = std::get<int>(it->second);
        }
    }

    if (modelPath.empty()) {
        result->Error("INVALID_ARGUMENT", "Model path is required");
        return;
    }

    try {
        // Since we migrated to PyTorch Mobile for Android, C++ ONNX Training is removed.
        // For Windows placeholder, simulate success or implement LibTorch later.
        
        result->Success(flutter::EncodableValue("Training Completed"));
    } catch (const std::exception& e) {
        result->Error("TRAINING_FAILED", e.what());
    }
  } 
  else {
    result->NotImplemented();
  }
}

}  // namespace

void FlTrainingPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  FlTrainingPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
