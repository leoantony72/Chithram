import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:onnxruntime/onnxruntime.dart';

// ---------------------------------------------------------------------------
// Messages (plain Dart objects — must be sendable across isolates)
// ---------------------------------------------------------------------------

class _TextInitMsg {
  final String modelPath;
  final SendPort replyPort;
  _TextInitMsg(this.modelPath, this.replyPort);
}

class _TextInferMsg {
  /// Pre-tokenized CLIP tokens (length 77, from ClipTokenizer on main thread).
  final Int64List tokens;
  final int eosPos;
  final SendPort replyPort;
  _TextInferMsg(this.tokens, this.eosPos, this.replyPort);
}

// ---------------------------------------------------------------------------
// Background isolate entry point (must be top-level for Isolate.spawn)
// ---------------------------------------------------------------------------

void _textIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  OrtSession? session;
  const int imageSize = 256;

  receivePort.listen((message) async {
    if (message is _TextInitMsg) {
      try {
        OrtEnv.instance.init();
        final opts = OrtSessionOptions();
        try {
          session = OrtSession.fromFile(File(message.modelPath), opts);
        } catch (_) {
          // Windows path encoding fallback
          final bytes = await File(message.modelPath).readAsBytes();
          session = OrtSession.fromBuffer(bytes, opts);
        }
        message.replyPort.send(true);
      } catch (e) {
        print('[SemanticTextWorker] Init error: $e');
        message.replyPort.send(false);
      }
      return;
    }

    if (message is _TextInferMsg) {
      if (session == null) {
        message.replyPort.send(<double>[]);
        return;
      }
      try {
        // Text tensor: [1, 77]
        final textTensor = OrtValueTensor.createTensorWithDataList(
          message.tokens,
          [1, 77],
        );

        // Dummy image tensor (not used for text branch)
        final dummyImage = Float32List(1 * 3 * imageSize * imageSize);
        final imageTensor = OrtValueTensor.createTensorWithDataList(
          dummyImage,
          [1, 3, imageSize, imageSize],
        );

        // EOS position tensor: [1]
        final eosData = Int64List.fromList([message.eosPos]);
        final eosTensor = OrtValueTensor.createTensorWithDataList(eosData, [1]);

        final inputs = {
          'image': imageTensor,
          'text': textTensor,
          'argmax': eosTensor,
        };
        final runOptions = OrtRunOptions();
        final outputs = session!.run(runOptions, inputs);

        imageTensor.release();
        textTensor.release();
        eosTensor.release();
        runOptions.release();

        final raw = (outputs[1]?.value as List<List<double>>)[0];

        // L2 normalise
        double sumSq = 0;
        for (final v in raw) sumSq += v * v;
        final mag = math.sqrt(sumSq);
        final normalised = mag > 1e-12 ? raw.map((v) => v / mag).toList() : raw;

        message.replyPort.send(normalised);
      } catch (e) {
        print('[SemanticTextWorker] Infer error: $e');
        message.replyPort.send(<double>[]);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Public API — used by SemanticService
// ---------------------------------------------------------------------------

/// A long-lived background isolate that runs ONNX text-embedding inference.
/// Tokenization happens on the main thread (needs rootBundle); only the heavy
/// ONNX forward pass runs here, keeping the Flutter UI completely free.
class SemanticTextWorker {
  Isolate? _isolate;
  SendPort? _sendPort;

  bool get isReady => _sendPort != null;

  /// Spawns the isolate and loads the model at [modelPath].
  Future<bool> start(String modelPath) async {
    final initPort = ReceivePort();
    _isolate = await Isolate.spawn(_textIsolateMain, initPort.sendPort);
    _sendPort = await initPort.first as SendPort;
    initPort.close();

    final readyPort = ReceivePort();
    _sendPort!.send(_TextInitMsg(modelPath, readyPort.sendPort));
    final success = await readyPort.first as bool;
    readyPort.close();
    return success;
  }

  /// Runs ONNX text inference for pre-tokenized [tokens] (Int64, length 77).
  Future<List<double>> infer(Int64List tokens, int eosPos) async {
    if (_sendPort == null) return [];
    final replyPort = ReceivePort();
    _sendPort!.send(_TextInferMsg(tokens, eosPos, replyPort.sendPort));
    final result = await replyPort.first as List<double>;
    replyPort.close();
    return result;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }
}
