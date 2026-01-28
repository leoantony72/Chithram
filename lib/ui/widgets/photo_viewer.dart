import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:extended_image/extended_image.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import '../../services/thumbnail_cache.dart';

class PhotoViewer extends StatefulWidget {
  final AssetEntity asset;
  final bool isActive;

  const PhotoViewer({
    super.key, 
    required this.asset,
    required this.isActive,
  });

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> with AutomaticKeepAliveClientMixin {
  Uint8List? _cachedThumbnail;

  @override
  void initState() {
    super.initState();
    // Get the instant thumbnail from cache to show immediately
    _cachedThumbnail = ThumbnailCache().getMemory(widget.asset.id);
  }

  @override
  bool get wantKeepAlive => true;

  final GlobalKey<ExtendedImageGestureState> _gestureKey = GlobalKey<ExtendedImageGestureState>();
  bool _allowOriginal = false;

  @override
  void didUpdateWidget(PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isActive && _allowOriginal) {
      // Reset to low-res when swiped away to free memory
      if (mounted) {
        setState(() {
          _allowOriginal = false;
          _gestureKey.currentState?.reset();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final mediaQuery = MediaQuery.of(context);
    final pixelRatio = mediaQuery.devicePixelRatio;
    final targetWidth = (mediaQuery.size.width * pixelRatio).toInt();
    final targetHeight = (mediaQuery.size.height * pixelRatio).toInt();
    
    // Only upgrade if necessary
    final bool useOriginal = _allowOriginal && 
        (widget.asset.width > targetWidth || widget.asset.height > targetHeight);

    final imageProvider = AssetEntityImageProvider(
      widget.asset,
      isOriginal: useOriginal,
      thumbnailSize: useOriginal ? null : ThumbnailSize(targetWidth, targetHeight),
      thumbnailFormat: ThumbnailFormat.jpeg,
    );

    Widget content = Listener(
      onPointerUp: (_) {
         final state = _gestureKey.currentState;
         if (state != null) {
           final scale = state.gestureDetails?.totalScale ?? 1.0;
           // If user zoomed in significantly, load full res
           if (scale > 1.5 && !_allowOriginal) {
             setState(() {
               _allowOriginal = true;
             });
           }
         }
      },
      child: ExtendedImage(
        extendedImageGestureKey: _gestureKey,
        image: imageProvider,
        fit: BoxFit.contain,
        mode: ExtendedImageMode.gesture,
        gaplessPlayback: true, 
        enableSlideOutPage: true,
        initGestureConfigHandler: (state) {
          return GestureConfig(
            minScale: 0.9,
            animationMinScale: 0.7,
            maxScale: 4.0, 
            animationMaxScale: 4.5,
            speed: 1.0,
            inertialSpeed: 100.0,
            initialScale: 1.0,
            inPageView: true,
            initialAlignment: InitialAlignment.center,
          );
        },
        loadStateChanged: (ExtendedImageState state) {
           switch (state.extendedImageLoadState) {
             case LoadState.loading:
               // If upgrading to original, return null to let gaplessPlayback 
               // show the previous Screen Nail image.
               if (useOriginal) return null;
               
               // Otherwise (initial load), show tiny thumbnail
               if (_cachedThumbnail != null) {
                 return Image.memory(
                   _cachedThumbnail!,
                   fit: BoxFit.contain,
                   gaplessPlayback: true,
                 );
               }
               return const Center(child: CircularProgressIndicator(color: Colors.white));
               
             case LoadState.completed:
               // If using original, just show it (smooth transition handled by gapless)
               if (useOriginal) return state.completedWidget;

               // For initial load, fade in
               return TweenAnimationBuilder<double>(
                 tween: Tween(begin: 0.0, end: 1.0),
                 duration: const Duration(milliseconds: 250),
                 curve: Curves.easeOut,
                 builder: (context, value, child) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                         if (_cachedThumbnail != null && value < 1.0)
                           Image.memory(
                             _cachedThumbnail!,
                             fit: BoxFit.contain,
                             gaplessPlayback: true,
                           ),
                         Opacity(
                           opacity: value,
                           child: state.completedWidget,
                         ),
                      ],
                    );
                 },
               );
               
             case LoadState.failed:
               return Center(
                 child: Column(
                   mainAxisAlignment: MainAxisAlignment.center,
                   children: [
                     const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 64),
                     const SizedBox(height: 16),
                     const Text(
                       "Could not load image",
                       style: TextStyle(color: Colors.white70, fontSize: 16),
                     ),
                     const SizedBox(height: 8),
                     TextButton.icon(
                       style: TextButton.styleFrom(
                         foregroundColor: Colors.white,
                         backgroundColor: Colors.white10,
                       ),
                       onPressed: () {
                          state.reLoadImage();
                       },
                       icon: const Icon(Icons.refresh),
                       label: const Text("Retry"),
                     )
                   ],
                 ),
               );
           }
        },
      ),
    );

    if (widget.isActive) {
      content = Hero(
        tag: widget.asset.id,
        child: content,
      );
    }

    return content;
  }
}

