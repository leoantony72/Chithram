import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

// ---------------------------------------------------------------------------
// Messages (must be sendable across isolates — plain Dart objects only)
// ---------------------------------------------------------------------------

class _InitMsg {
  final String modelPath;
  final SendPort replyPort;
  _InitMsg(this.modelPath, this.replyPort);
}

class _EmbedMsg {
  final Uint8List bytes;
  final SendPort replyPort;
  _EmbedMsg(this.bytes, this.replyPort);
}

// ---------------------------------------------------------------------------
// Background isolate entry point (top-level so Isolate.spawn can reference it)
// ---------------------------------------------------------------------------

void _isolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  // Send back our SendPort so the caller can talk to us
  mainSendPort.send(receivePort.sendPort);

  OrtSession? session;
  const int imageSize = 256;

  receivePort.listen((message) async {
    if (message is _InitMsg) {
      try {
        OrtEnv.instance.init();
        final opts = OrtSessionOptions();
        session = OrtSession.fromFile(File(message.modelPath), opts);
        message.replyPort.send(true);
      } catch (e) {
        print('[IndexingWorker] Init error: $e');
        message.replyPort.send(false);
      }
      return;
    }

    if (message is _EmbedMsg) {
      if (session == null) {
        message.replyPort.send(<double>[]);
        return;
      }
      try {
        final decoded = img.decodeImage(message.bytes);
        if (decoded == null) {
          message.replyPort.send(<double>[]);
          return;
        }

        final resized = img.copyResize(decoded,
            width: imageSize, height: imageSize,
            interpolation: img.Interpolation.linear);

        final floatList = Float32List(3 * imageSize * imageSize);
        for (var c = 0; c < 3; c++) {
          for (var y = 0; y < imageSize; y++) {
            for (var x = 0; x < imageSize; x++) {
              final pixel = resized.getPixel(x, y);
              final val = c == 0
                  ? pixel.r.toDouble()
                  : (c == 1 ? pixel.g.toDouble() : pixel.b.toDouble());
              floatList[c * imageSize * imageSize + y * imageSize + x] =
                  val / 255.0;
            }
          }
        }

        final inputTensor = OrtValueTensor.createTensorWithDataList(
            floatList, [1, 3, imageSize, imageSize]);
        final dummyText = Int64List(77);
        final textTensor =
            OrtValueTensor.createTensorWithDataList(dummyText, [1, 77]);
        final dummyEos = Int64List.fromList([1]);
        final eosTensor =
            OrtValueTensor.createTensorWithDataList(dummyEos, [1]);

        final inputs = {
          'image': inputTensor,
          'text': textTensor,
          'argmax': eosTensor
        };
        final runOptions = OrtRunOptions();
        final outputs = session!.run(runOptions, inputs);

        inputTensor.release();
        textTensor.release();
        eosTensor.release();
        runOptions.release();

        final raw = (outputs[0]?.value as List<List<double>>)[0];

        // L2 normalise
        double sumSq = 0;
        for (final v in raw) sumSq += v * v;
        final mag = math.sqrt(sumSq);
        final normalised =
            mag > 1e-12 ? raw.map((v) => v / mag).toList() : raw;

        message.replyPort.send(normalised);
      } catch (e) {
        print('[IndexingWorker] Embed error: $e');
        message.replyPort.send(<double>[]);
      }
    }
  });
}

// ---------------------------------------------------------------------------
// Public API — used by PhotoProvider
// ---------------------------------------------------------------------------

/// A long-lived background isolate that runs ONNX image-embedding inference.
/// All heavy computation (decoding, resizing, model inference) runs off the
/// main isolate, keeping the Flutter UI completely free.
class SemanticIndexingWorker {
  Isolate? _isolate;
  SendPort? _sendPort;

  bool get isReady => _sendPort != null;

  /// Spawns the isolate and loads the model at [modelPath].
  /// Returns `false` if the model could not be loaded.
  Future<bool> start(String modelPath) async {
    final initPort = ReceivePort();
    _isolate = await Isolate.spawn(_isolateMain, initPort.sendPort);
    _sendPort = await initPort.first as SendPort;
    initPort.close();

    // Ask the isolate to load the ONNX model
    final readyPort = ReceivePort();
    _sendPort!.send(_InitMsg(modelPath, readyPort.sendPort));
    final success = await readyPort.first as bool;
    readyPort.close();
    return success;
  }

  /// Generates an image embedding from raw image [bytes].
  /// Returns an empty list on failure.
  Future<List<double>> embed(Uint8List bytes) async {
    if (_sendPort == null) return [];
    final replyPort = ReceivePort();
    _sendPort!.send(_EmbedMsg(bytes, replyPort.sendPort));
    final result = await replyPort.first as List<double>;
    replyPort.close();
    return result;
  }

  /// Tears down the isolate and releases resources.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }
}
