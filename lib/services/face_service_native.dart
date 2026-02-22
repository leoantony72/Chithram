import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'model_service.dart';

class FaceService {
  FaceDetector? _faceDetector;
  OrtSession? _recognitionSession;
  
  // MobileFaceNet input size
  static const int _recInputSize = 112;

  final ModelService _modelService = ModelService();

  Future<void> initialize() async {
    if (_faceDetector != null) return; // Already initialized

    // 1. Initialize Google ML Kit Face Detector (Mobile Only)
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          enableContours: true,
          enableLandmarks: true,
          performanceMode: FaceDetectorMode.accurate,
        ),
      );
    }

    // 2. Initialize ONNX Runtime for Recognition
    OrtEnv.instance.init();

    // Only load the recognition model
    final recModelPath = await _modelService.getModelPath(ModelService.faceRecognitionModelName);

    if (recModelPath != null) {
      try {
        final sessionOptions = OrtSessionOptions();
        
        // Workaround for Windows ONNX Runtime FFI char* vs wchar_t* string decoding bug
        // which completely corrupts file paths like "C:\Users\...".
        // Instead of passing the string path, we load the raw bytes directly in Dart memory!
        final modelBytes = await File(recModelPath).readAsBytes();
        _recognitionSession = OrtSession.fromBuffer(modelBytes, sessionOptions);
        
        print('FaceService: Recognition model loaded successfully from buffer.');
      } catch (e) {
        print('FaceService: Error loading recognition model: $e');
      }
    } else {
      print('FaceService: Recognition model not found.');
    }
  }

  void dispose() {
    _faceDetector?.close();
    _recognitionSession?.release();
    OrtEnv.instance.release();
  }

  // --- Detection (ML Kit) ---

  Future<List<LocalFace>> detectFaces(File imageFile) async {
    try {
      if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
        // Run Desktop Fallback Python Detector via virtual environment
        final String pythonCmd = !kIsWeb && Platform.isWindows ? '.venv\\Scripts\\python.exe' : 'python';
        final detModelPath = await _modelService.getModelPath(ModelService.faceDetectionModelName);
        
        final result = await Process.run(pythonCmd, [
          'scripts/desktop_detect.py',
          imageFile.path,
          detModelPath ?? '',
        ]);
        
        if (result.exitCode != 0) {
           print("Desktop Face Detect Error: ${result.stderr}");
           return [];
        }
        
        final String out = result.stdout.toString().trim();
        if (out.isEmpty) return [];
        
        final List<dynamic> jsonList = jsonDecode(out);
        final List<LocalFace> faces = [];
        
        for (var item in jsonList) {
           final box = item['box'];
           final le = item['left_eye'];
           final re = item['right_eye'];
           
           faces.add(LocalFace(
              Rect.fromLTWH(box[0].toDouble(), box[1].toDouble(), box[2].toDouble(), box[3].toDouble()),
              Point<int>(le[0], le[1]),
              Point<int>(re[0], re[1]),
           ));
        }
        
        return faces;
      } else {
        // Run Native Android/iOS MLKit Detector
        if (_faceDetector == null) return [];
        final inputImage = InputImage.fromFile(imageFile);
        final mlFaces = await _faceDetector!.processImage(inputImage);
        
        return mlFaces.map((f) {
           final le = f.landmarks[FaceLandmarkType.leftEye];
           final re = f.landmarks[FaceLandmarkType.rightEye];
           
           return LocalFace(
             f.boundingBox,
             le != null ? Point<int>(le.position.x, le.position.y) : null,
             re != null ? Point<int>(re.position.x, re.position.y) : null,
           );
        }).toList();
      }
    } catch (e) {
      print('FaceService: Error detecting faces: $e');
      return [];
    }
  }

  // --- Recognition (ONNX MobileFaceNet) ---

  // Refactored to take Rect and Landmarks
  Future<FaceData?> getEmbeddingFromData(File originalImageFile, Rect faceRect, {Point<int>? leftEye, Point<int>? rightEye}) async {
    if (_recognitionSession == null) return null;

    try {
        final bytes = await originalImageFile.readAsBytes();
        
        // Decode and Crop in background isolate
        final result = await compute(_preprocessFace, _CropRequest(bytes, faceRect, leftEye, rightEye));
        
        if (result == null) return null;

        final embedding = await _runInference(result.floatList);
        if (embedding.isEmpty) return null;

        return FaceData(embedding, result.thumbnailBytes);
    } catch (e) {
        print('FaceService: Error preparing embedding: $e');
        return null;
    }
  }

  Future<List<double>> _runInference(Float32List floatList) async {
    if (_recognitionSession == null) return [];

    try {
      final inputTensor = OrtValueTensor.createTensorWithDataList(
        floatList, 
        [1, 3, _recInputSize, _recInputSize]
      );

      final inputName = _recognitionSession!.inputNames.first;
      final inputs = {inputName: inputTensor};
      final runOptions = OrtRunOptions();
      
      final outputs = _recognitionSession!.run(runOptions, inputs);
      
      inputTensor.release();
      runOptions.release();

      final outputValue = outputs[0]?.value;
      if (outputValue == null) return [];

      final outputData = outputValue as List<List<double>>;
      final rawEmbedding = outputData[0];
      
      // L2 Normalization
      double sum = 0;
      for (var x in rawEmbedding) sum += x * x;
      final magnitude = sqrt(sum);
      
      if (magnitude > 0) {
        return rawEmbedding.map((e) => e / magnitude).toList();
      }
      return rawEmbedding;
    } catch (e) {
      print('FaceService: Inference error: $e');
      return [];
    }
  }

  static Future<_PreprocessingResult?> _preprocessFace(_CropRequest request) async {
    try {
        final image = img.decodeImage(request.imageBytes);
        if (image == null) return null;

        var procImage = image;
        var rect = request.boundingBox;

        // --- Alignment ---
        if (request.leftEye != null && request.rightEye != null) {
          final le = request.leftEye!;
          final re = request.rightEye!;
          
          // Calculate angle (eyes line)
          final dx = re.x - le.x;
          final dy = re.y - le.y;
          final angleRad = atan2(dy, dx);
          final angleDeg = angleRad * 180 / pi;

          // Rotate if significant (> 3 degrees tilt)
          if (angleDeg.abs() > 3.0) {
             final correctionAngleDeg = -angleDeg;
             final correctionAngleRad = -angleRad;
             
             // Rotate image around center
             procImage = img.copyRotate(image, angle: correctionAngleDeg);
             
             // Transform Face Box Center
             final oldCx = image.width / 2.0;
             final oldCy = image.height / 2.0;
             final newCx = procImage.width / 2.0;
             final newCy = procImage.height / 2.0;
             
             final faceCx = rect.center.dx;
             final faceCy = rect.center.dy;

             final px = faceCx - oldCx;
             final py = faceCy - oldCy;

             final cosA = cos(correctionAngleRad);
             final sinA = sin(correctionAngleRad);
             
             final nx = newCx + (px * cosA - py * sinA);
             final ny = newCy + (px * sinA + py * cosA);

             // Update Rect to new coordinates
             rect = Rect.fromCenter(center: Offset(nx, ny), width: rect.width, height: rect.height);
          }
        }
        
        // --- Thumbnail Generation ---
        // Add padding
        final double pad = 0.2; 
        final w0 = rect.width;
        final h0 = rect.height;
        final x0 = rect.left - (w0 * pad);
        final y0 = rect.top - (h0 * pad);
        
        // Ensure within bounds of procImage (which might be the rotated one)
        final int imgW = procImage.width;
        final int imgH = procImage.height;

        final int x = max(0, x0.toInt());
        final int y = max(0, y0.toInt());
        
        // Careful with width calculation if x + w > imgW
        int w = (w0 * (1 + 2 * pad)).toInt();
        int h = (h0 * (1 + 2 * pad)).toInt();
        
        if (x + w > imgW) w = imgW - x;
        if (y + h > imgH) h = imgH - y;

        if (w <= 0 || h <= 0) return null;

        // Visual Thumbnail
        img.Image thumbCrop = img.copyCrop(procImage, x: x, y: y, width: w, height: h);
        thumbCrop = img.copyResize(thumbCrop, width: 200, height: 200);
        final thumbnailBytes = Uint8List.fromList(img.encodeJpg(thumbCrop, quality: 80));

        // --- Model Input Generation ---
        // Tight Crop
        final int mx = max(0, rect.left.toInt());
        final int my = max(0, rect.top.toInt());
        
        // Ensure model crop is also safe
        int mw = rect.width.toInt();
        int mh = rect.height.toInt();
        
        if (mx + mw > imgW) mw = imgW - mx;
        if (my + mh > imgH) mh = imgH - my;
        
        img.Image modelCrop = img.copyCrop(procImage, x: mx, y: my, width: mw, height: mh);
        modelCrop = img.copyResize(modelCrop, width: _recInputSize, height: _recInputSize);

        // Normalize [-1, 1]
        final floatList = Float32List(_recInputSize * _recInputSize * 3);
        var index = 0;
        final modelBytes = modelCrop.getBytes(); // Direct access might be faster but order depends on format
        // Using getPixel is safe but slow. For 112x112 it's ~37k iterations. tolerable.
        
        // Optimization: Iterate y, then x
        for (var c = 0; c < 3; c++) {
            for (var py = 0; py < _recInputSize; py++) {
                for (var px = 0; px < _recInputSize; px++) {
                    final pixel = modelCrop.getPixel(px, py);
                    double val = 0;
                    if (c == 0) val = pixel.r.toDouble();
                    else if (c == 1) val = pixel.g.toDouble();
                    else val = pixel.b.toDouble();
                    
                    floatList[index++] = (val - 127.5) / 128.0;
                }
            }
        }

        return _PreprocessingResult(floatList, thumbnailBytes);
    } catch (e) {
        print('Preprocessing Error: $e');
        return null;
    }
  }
}

class FaceData {
  final List<double> embedding;
  final Uint8List thumbnail;
  FaceData(this.embedding, this.thumbnail);
}

class LocalFace {
  final Rect boundingBox;
  final Point<int>? leftEye;
  final Point<int>? rightEye;
  LocalFace(this.boundingBox, this.leftEye, this.rightEye);
}

class _CropRequest {
  final Uint8List imageBytes;
  final Rect boundingBox;
  final Point<int>? leftEye;
  final Point<int>? rightEye;
  _CropRequest(this.imageBytes, this.boundingBox, this.leftEye, this.rightEye);
}

class _PreprocessingResult {
  final Float32List floatList;
  final Uint8List thumbnailBytes;
  _PreprocessingResult(this.floatList, this.thumbnailBytes);
}
