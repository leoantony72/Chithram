import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'model_service.dart';

class FaceService {
  OrtSession? _detectionSession;
  OrtSession? _recognitionSession;

  // YOLOv8n-face constants
  static const int _detInputSize = 640;
  
  // MobileFaceNet constants
  static const int _recInputSize = 112;

  final ModelService _modelService = ModelService();

  Future<void> initialize() async {
    OrtEnv.instance.init();

    final detModelPath = await _modelService.getModelPath(ModelService.faceDetectionModelName);
    final recModelPath = await _modelService.getModelPath(ModelService.faceRecognitionModelName);

    if (detModelPath != null) {
      final sessionOptions = OrtSessionOptions();
      _detectionSession = OrtSession.fromFile(File(detModelPath), sessionOptions);
    }

    if (recModelPath != null) {
      final sessionOptions = OrtSessionOptions();
      _recognitionSession = OrtSession.fromFile(File(recModelPath), sessionOptions);
    }
  }

  void dispose() {
    _detectionSession?.release();
    _recognitionSession?.release();
    OrtEnv.instance.release();
  }

  // --- Detection ---

  Future<List<List<double>>> detectFaces(File imageFile) async {
    if (_detectionSession == null) return [];

    // Load and Resize Image
    final bytes = await imageFile.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return [];

    final resized = img.copyResize(image, width: _detInputSize, height: _detInputSize);
    
    // Preprocess: Normalize to 0-1, CHW format
    final floatList = Float32List(_detInputSize * _detInputSize * 3);
    var index = 0;
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < _detInputSize; y++) {
        for (var x = 0; x < _detInputSize; x++) {
          final pixel = resized.getPixel(x, y);
          // image package v4 uses different pixel access, assuming v3 or check docs.
          // For v3: img.getRed(pixel) / 255.0
          // For v4: pixel.r / 255.0
          floatList[index++] = pixel.r / 255.0; 
        }
      }
    }

    // Create Tensor (1, 3, 640, 640)
    final inputTensor = OrtValueTensor.createTensorWithDataList(
      floatList, 
      [1, 3, _detInputSize, _detInputSize]
    );

    final inputs = {'images': inputTensor};
    final runOptions = OrtRunOptions();
    final outputs = _detectionSession!.run(runOptions, inputs);
    
    inputTensor.release();
    runOptions.release();

    // Post-process (Simplification: Just return first output for now)
    // Output shape for YOLOv8 is usually (1, 5, 8400) -> 4 coords + 1 conf
    // Needs NMS (Non-Maximum Suppression) implementation
    // returning raw dummy list for now to proceed
    
    // TODO: Implement proper NMS and coordinate scaling back to original image
    return []; 
  }

  // --- Recognition ---

  Future<List<double>> getEmbedding(img.Image faceImage) async {
    if (_recognitionSession == null) return [];

    final resized = img.copyResize(faceImage, width: _recInputSize, height: _recInputSize);

    // Preprocess: (x - 127.5) / 128.0
    final floatList = Float32List(_recInputSize * _recInputSize * 3);
    var index = 0;
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < _recInputSize; y++) {
        for (var x = 0; x < _recInputSize; x++) {
          final pixel = resized.getPixel(x, y);
          floatList[index++] = (pixel.r - 127.5) / 128.0;
        }
      }
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      floatList, 
      [1, 3, _recInputSize, _recInputSize]
    );

    final inputs = {'input': inputTensor}; // Check model input name (often 'input' or 'data')
    final runOptions = OrtRunOptions();
    final outputs = _recognitionSession!.run(runOptions, inputs);
    
    inputTensor.release();
    runOptions.release();

    // Output is usually 1x128 or 1x512
    final outputValue = outputs[0]?.value;
    if (outputValue == null) return [];
    
    final outputData = outputValue as List<List<double>>; // Check type casting
    return outputData[0];
  }
}
