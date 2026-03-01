import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../model_service.dart';
import 'tokenizer.dart';

class SemanticService {
  OrtSession? _session;
  final ClipTokenizer _tokenizer = ClipTokenizer();
  final ModelService _modelService = ModelService();

  static const int imageSize = 256;
  static const String modelName = 'semantic/mobileclip2_s0';

  Future<void> initialize() async {
    if (_session != null) return;

    OrtEnv.instance.init();
    await _tokenizer.initialize();
    
    final foundPath = await _findModelPath();
    if (foundPath == null) {
      debugPrint('SemanticService: Model not found in any of the expected locations.');
      return;
    }

    await _loadModel(foundPath);
  }

  Future<String?> _findModelPath() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final downloadedPath = await _modelService.getModelPath(ModelService.semanticSearchModelName);
    
    final List<String> possiblePaths = [
      if (downloadedPath != null) downloadedPath,
      p.join(docsDir.path, 'semantic-search.onnx'),
      'backend/models/semantic-search.onnx',
      'backend/models/semantic/mobileclip2_s0_v11.onnx',
      'backend/models/semantic/mobileclip2_s0.onnx',
    ];

    for (var path in possiblePaths) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  Future<void> _loadModel(String path) async {
    final sessionOptions = OrtSessionOptions();
    
    // 1. Try file-based loading (Memory Efficient)
    try {
      _session = OrtSession.fromFile(File(path), sessionOptions);
      debugPrint('SemanticService: Model loaded from file: $path');
      return;
    } catch (e) {
      debugPrint('SemanticService: fromFile failed, trying fallback: $e');
    }

    // 2. Fallback to buffer-based loading
    try {
      final bytes = await File(path).readAsBytes();
      _session = OrtSession.fromBuffer(bytes, sessionOptions);
      debugPrint('SemanticService: Model loaded from buffer: $path');
    } catch (e) {
      debugPrint('SemanticService: All loading attempts failed: $e');
    }
  }

  void dispose() {
    _session?.release();
    OrtEnv.instance.release();
  }

  Future<List<double>> generateImageEmbedding(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      return generateImageEmbeddingFromBytes(bytes);
    } catch (e) {
      print('SemanticService: Image File Embedding Error: $e');
      return [];
    }
  }

  Future<List<double>> generateImageEmbeddingFromBytes(Uint8List bytes) async {
    if (_session == null) await initialize();
    if (_session == null) return [];

    try {
      final image = img.decodeImage(bytes);
      if (image == null) return [];

      // 1. Resize to 256x256
      final resized = img.copyResize(image, width: imageSize, height: imageSize, interpolation: img.Interpolation.linear);

      // 2. Preprocess: MobileCLIP2 S0/S1/S2 uses mean=(0,0,0) std=(1,1,1)
      // i.e. just pixel/255.0 — NO mean subtraction, NO std division.
      // (S3/S4/L-14 use OpenAI CLIP stats, but S0 does NOT.)
      final floatList = Float32List(1 * 3 * imageSize * imageSize);
      
      for (var c = 0; c < 3; c++) {
        for (var y = 0; y < imageSize; y++) {
          for (var x = 0; x < imageSize; x++) {
            final pixel = resized.getPixel(x, y);
            double val = 0;
            if (c == 0) val = pixel.r.toDouble();
            else if (c == 1) val = pixel.g.toDouble();
            else val = pixel.b.toDouble();

            floatList[c * imageSize * imageSize + y * imageSize + x] = val / 255.0;
          }
        }
      }

      final inputTensor = OrtValueTensor.createTensorWithDataList(floatList, [1, 3, imageSize, imageSize]);
      final dummyText = Int64List(77); 
      final textTensor = OrtValueTensor.createTensorWithDataList(dummyText, [1, 77]);
      // eos_idx dummy: position 1 (ignored for image branch in S2, unused in S0)
      final dummyEos = Int64List.fromList([1]);
      final eosTensor = OrtValueTensor.createTensorWithDataList(dummyEos, [1]);

      final inputs = {'image': inputTensor, 'text': textTensor, 'argmax': eosTensor};
      final runOptions = OrtRunOptions();
      final outputs = _session!.run(runOptions, inputs);

      inputTensor.release();
      textTensor.release();
      eosTensor.release();
      runOptions.release();

      final result = outputs[0]?.value as List<List<double>>;
      return _l2Normalize(result[0]);
    } catch (e) {
      debugPrint('SemanticService: Image Bytes Embedding Error: $e');
      return [];
    }
  }

  Future<List<double>> generateTextEmbedding(String text) async {
    if (_session == null) await initialize();
    if (_session == null) return [];

    try {
      final tokens = _tokenizer.tokenize(text);
      final textData = Int64List.fromList(tokens);
      final textTensor = OrtValueTensor.createTensorWithDataList(textData, [1, 77]);

      final dummyImage = Float32List(1 * 3 * imageSize * imageSize);
      final imageTensor = OrtValueTensor.createTensorWithDataList(dummyImage, [1, 3, imageSize, imageSize]);

      // Compute eos_idx: position of EOS token (49407) in the tokenized sequence.
      // MobileCLIP2-S2 needs this to pool the correct text feature without ArgMax.
      const int eosTokenId = 49407;
      int eosPos = tokens.indexOf(eosTokenId);
      if (eosPos < 0) eosPos = 76; // fallback: last position
      final eosData = Int64List.fromList([eosPos]);
      final eosTensor = OrtValueTensor.createTensorWithDataList(eosData, [1]);

      final inputs = {'image': imageTensor, 'text': textTensor, 'argmax': eosTensor};
      final runOptions = OrtRunOptions();
      final outputs = _session!.run(runOptions, inputs);

      imageTensor.release();
      textTensor.release();
      eosTensor.release();
      runOptions.release();

      final result = outputs[1]?.value as List<List<double>>;
      return _l2Normalize(result[0]);
    } catch (e) {
      print('SemanticService: Text Embedding Error: $e');
      return [];
    }
  }

  List<double> _l2Normalize(List<double> vector) {
    double sumOfSquares = 0;
    for (var x in vector) {
      sumOfSquares += x * x;
    }
    
    if (sumOfSquares == 0) return vector;
    
    final double magnitude = math.sqrt(sumOfSquares);
    // debugPrint('SemanticService: Vector magnitude: ${magnitude.toStringAsFixed(4)}');
    
    if (magnitude < 1e-12) return vector;

    return vector.map((x) => x / magnitude).toList();
  }
}
