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
  Uint8List? _placeholderBytes;

  @override
  void initState() {
    super.initState();
    // Grab the low-res thumb from the cache for immediate display
    _placeholderBytes = ThumbnailCache().getMemory(widget.asset.id);
  }

  @override
  bool get wantKeepAlive => true;

  final GlobalKey<ExtendedImageGestureState> _gestureKey = GlobalKey<ExtendedImageGestureState>();
  bool _allowOriginal = false;

  @override
  void didUpdateWidget(PhotoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Whenever the page becomes inactive (swiped away), strictly reset everything.
    // This ensures that when we come back, the image is at 1.0 scale and low-res.
    if (!widget.isActive) {
      if (mounted) {
        // Reset gesture state (zoom/pan)
        _gestureKey.currentState?.reset();
        
        // Reset resolution state if needed
        if (_allowOriginal) {
          setState(() {
            _allowOriginal = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Check standard build context logic
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
        enableSlideOutPage: false,
        onDoubleTap: (ExtendedImageGestureState state) {
          final double beginScale = state.gestureDetails?.totalScale ?? 1.0;
          double targetScale = 1.0;

          if (beginScale <= 1.001) {
            targetScale = 3.0; // Zoom in
          }

          state.handleDoubleTap(
            scale: targetScale,
            doubleTapPosition: state.pointerDownPosition,
          );

          if (targetScale > 1.0 && !_allowOriginal) {
             Future.delayed(const Duration(milliseconds: 150), () {
               if (mounted) setState(() => _allowOriginal = true);
             });
          } 
        },
        initGestureConfigHandler: (state) {
          return GestureConfig(
            minScale: 0.9, 
            animationMinScale: 0.7,
            maxScale: 10.0, 
            animationMaxScale: 12.0,
            speed: 1.0,
            inertialSpeed: 100.0,
            initialScale: 1.0,
            inPageView: true,
            initialAlignment: InitialAlignment.center,
            cacheGesture: true,
          );
        },
        loadStateChanged: (ExtendedImageState state) {
           switch (state.extendedImageLoadState) {
             case LoadState.loading:
               if (useOriginal) return null; // Gapless
               
               if (_placeholderBytes != null) {
                 return Image.memory(
                   _placeholderBytes!,
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
                 duration: const Duration(milliseconds: 200),
                 curve: Curves.easeOut,
                 builder: (context, value, child) {
                    // Once animation is done (value=1.0), immediately remove the placeholder
                    // from the tree. This prevents the "duplicate image" ghost effect
                    // when zooming out (pinching < 1.0).
                    if (value >= 1.0) {
                      return state.completedWidget;
                    }
                    
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_placeholderBytes != null)
                           Image.memory(
                             _placeholderBytes!,
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
               // ...
               
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
      // Hero disabled to prevent glitches
      // content = Hero(tag: widget.asset.id, child: content);
    }

    return content;
  }
}

