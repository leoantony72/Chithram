# Download necessary ONNX Runtime Binaries for Inference
# No training binaries required for Android anymore (using PyTorch Mobile).
# Windows ONNX Runtime for inference can be acquired from standard 'microsoft.ml.onnxruntime' nuget.

Write-Host "Please manually download ONNX Runtime Inference packages if needed for Windows."
Write-Host "1. For Windows: Download 'Microsoft.ML.OnnxRuntime' (Nuget or GitHub Releases)"
Write-Host "   Extract 'include' to packages/fl_training_plugin/windows/third_party/onnxruntime/include"
Write-Host "   Extract 'lib' to packages/fl_training_plugin/windows/third_party/onnxruntime/lib"
Write-Host "   Ensure 'onnxruntime.lib' is present."

Write-Host "2. For Android: PyTorch Mobile handles training via Gradle dependencies."
Write-Host "   No manual C++ ONNX training libraries required for Android."

Write-Host "Plugin structure expected for Windows (if using inference via plugin):"
Write-Host "  packages/fl_training_plugin/windows/third_party/onnxruntime/"
