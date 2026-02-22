import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../../models/remote_image.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';

class RemotePhotoViewer extends StatefulWidget {
  final RemoteImage remote;
  final bool isActive;

  const RemotePhotoViewer({
    super.key,
    required this.remote,
    required this.isActive,
  });

  @override
  State<RemotePhotoViewer> createState() => _RemotePhotoViewerState();
}

class _RemotePhotoViewerState extends State<RemotePhotoViewer> with AutomaticKeepAliveClientMixin {
  Uint8List? _originalBytes;
  Uint8List? _thumbBytes;
  bool _isLoading = false;
  String? _error;

  final GlobalKey<ExtendedImageGestureState> _gestureKey = GlobalKey<ExtendedImageGestureState>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    if (mounted) setState(() => _isLoading = true);
    
    try {
      final crypto = CryptoService();
      final session = await AuthService().loadSession();
      if (session == null) {
        if (mounted) setState(() => _error = "Not logged in");
        return;
      }
      final masterKeyBytes = session['masterKey'] as Uint8List;
      final key = SecureKey.fromList(crypto.sodium, masterKeyBytes);

      // 1. Fetch Thumbnail (Fast)
      if (_thumbBytes == null) {
        var url = widget.remote.thumb256Url;
        if (url.isEmpty) url = widget.remote.thumb64Url;
        if (url.isNotEmpty) {
           final tBytes = await BackupService().fetchAndDecryptFromUrl(url, key);
           if (mounted && tBytes != null) {
              setState(() => _thumbBytes = tBytes);
           }
        }
      }

      // 2. Fetch Original (Slow)
      // Only fetch if active? No, usually prefetched. 
      // But for memory safety, maybe delay? 
      // Actually, standard behavior is fetch.
      // RemotePhotoViewer is built by PageView builder, so it's built when needed.
      if (widget.remote.originalUrl.isNotEmpty) {
        final oBytes = await BackupService().fetchAndDecryptFromUrl(widget.remote.originalUrl, key);
        if (mounted) {
          if (oBytes != null) {
            setState(() {
              _originalBytes = oBytes;
              _isLoading = false;
            });
          } else {
             setState(() {
               _error = "Failed to decrypt original";
               _isLoading = false;
             });
          }
        }
      } else {
         if (mounted) setState(() => _isLoading = false);
      }

    } catch (e) {
      if (mounted) setState(() {
        _error = "Load Error: $e";
        _isLoading = false;
      });
    }
  }

  @override
  void didUpdateWidget(RemotePhotoViewer oldWidget) {
     super.didUpdateWidget(oldWidget);
     if (!widget.isActive) {
        // Reset zoom when swiped away
        if (_gestureKey.currentState != null) {
           _gestureKey.currentState!.reset();
        }
     }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    
    if (_originalBytes != null) {
      return ExtendedImage.memory(
        _originalBytes!,
        fit: BoxFit.contain,
        mode: ExtendedImageMode.gesture,
        extendedImageGestureKey: _gestureKey,
        gaplessPlayback: true,
        onDoubleTap: (ExtendedImageGestureState state) {
          final double beginScale = state.gestureDetails?.totalScale ?? 1.0;
          double targetScale = 1.0;
          if (beginScale <= 1.001) targetScale = 3.0;

          state.handleDoubleTap(
            scale: targetScale,
            doubleTapPosition: state.pointerDownPosition,
          );
        },
        initGestureConfigHandler: (state) {
          return GestureConfig(
            minScale: 0.9,
            animationMinScale: 0.7,
            maxScale: 10.0,
            animationMaxScale: 12.5,
            speed: 1.0,
            inertialSpeed: 100.0,
            initialScale: 1.0,
            inPageView: true,
            cacheGesture: true,
          );
        },
      );
    }

    // Show thumbnail/loading while waiting for original
    return Stack(
      alignment: Alignment.center,
      children: [
        if (_thumbBytes != null)
          ExtendedImage.memory(
            _thumbBytes!,
            fit: BoxFit.contain,
            mode: ExtendedImageMode.gesture,
            onDoubleTap: (ExtendedImageGestureState state) {
               final double beginScale = state.gestureDetails?.totalScale ?? 1.0;
               double targetScale = 1.0;
               if (beginScale <= 1.001) targetScale = 3.0;
               state.handleDoubleTap(scale: targetScale, doubleTapPosition: state.pointerDownPosition);
            },
            initGestureConfigHandler: (state) => GestureConfig(
              inPageView: true, 
              minScale: 0.9, 
              maxScale: 5.0,
              cacheGesture: true
            ),
          )
        else
          const Center(child: CircularProgressIndicator(color: Colors.white30)),
          
        if (_isLoading)
           const Center(child: CircularProgressIndicator(color: Colors.white)),
           
        if (_error != null)
           Center(
             child: Column(
               mainAxisSize: MainAxisSize.min,
               children: [
                 const Icon(Icons.error_outline, color: Colors.white54, size: 48),
                 Text(_error!, style: const TextStyle(color: Colors.white54)),
               ],
             ),
           )
      ],
    );
  }
}
