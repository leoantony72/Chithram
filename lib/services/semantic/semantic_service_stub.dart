import 'dart:typed_data';
import 'dart:io';

/// Web stub — all ONNX operations are no-ops on web.
class SemanticService {
  Future<void> initialize() async {}

  Future<List<double>> generateImageEmbedding(File imageFile) async => [];

  Future<List<double>> generateImageEmbeddingFromBytes(Uint8List bytes) async => [];

  Future<List<double>> generateTextEmbedding(String text) async => [];

  void dispose() {}
}
