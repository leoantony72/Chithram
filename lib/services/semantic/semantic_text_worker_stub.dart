import 'dart:typed_data';

/// Web stub — text worker is not supported on web.
class SemanticTextWorker {
  bool get isReady => false;

  Future<bool> start(String modelPath) async => false;

  Future<List<double>> infer(Int64List tokens, int eosPos) async => [];

  void dispose() {}
}
