import 'dart:typed_data';

/// Web stub — indexing worker is not supported on web.
class SemanticIndexingWorker {
  bool get isReady => false;

  Future<bool> start(String modelPath) async => false;

  Future<List<double>> embed(Uint8List bytes) async => [];

  void dispose() {}
}
