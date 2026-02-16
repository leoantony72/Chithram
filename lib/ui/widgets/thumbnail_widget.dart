import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import '../../services/thumbnail_cache.dart';

class ThumbnailWidget extends StatefulWidget {
  final AssetEntity entity;
  final ValueListenable<bool>? isFastScrolling;
  final String? heroTagPrefix;
  
  const ThumbnailWidget({
    super.key, 
    required this.entity,
    this.isFastScrolling,
    this.heroTagPrefix,
  });

  @override
  State<ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<ThumbnailWidget> {
  Uint8List? _bytes;
  bool _showImage = true;
  Timer? _timer;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initShowState();
    
    if (widget.isFastScrolling != null) {
      widget.isFastScrolling!.addListener(_onScrollStateChanged);
    }
  }

  void _initShowState() {
    if (widget.isFastScrolling?.value == true) {
      _showImage = false;
      _timer = Timer(const Duration(milliseconds: 60), () {
        if (mounted) {
           setState(() {
             _showImage = true;
           });
           _loadThumbnail();
        }
      });
    } else {
      _showImage = true;
      // Try synchronous memory load first for instant render
      _bytes = ThumbnailCache().getMemory(widget.entity.id);
      if (_bytes == null) {
         _loadThumbnail();
      }
    }
  }

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entity.id != oldWidget.entity.id) {
       _timer?.cancel();
       _bytes = null; // Clear old image immediately
       _initShowState();
    }
    
    if (widget.isFastScrolling != oldWidget.isFastScrolling) {
       oldWidget.isFastScrolling?.removeListener(_onScrollStateChanged);
       widget.isFastScrolling?.addListener(_onScrollStateChanged);
    }
  }

  void _onScrollStateChanged() {
    if (widget.isFastScrolling?.value == false && !_showImage) {
      _timer?.cancel();
      if (mounted) {
        setState(() {
          _showImage = true;
        });
        _loadThumbnail();
      }
    }
  }

  Future<void> _loadThumbnail() async {
    if (_bytes != null) return; // Already have data
    if (_isLoading) return;
    
    _isLoading = true;

    // 1. Check Memory again (in case it populated elsewhere)
    final mem = ThumbnailCache().getMemory(widget.entity.id);
    if (mem != null) {
      if (mounted) setState(() => _bytes = mem);
      _isLoading = false;
      return;
    }

    // 2. Load Async (Disk -> Gen)
    try {
      final bytes = await ThumbnailCache().getThumbnail(widget.entity);
      if (mounted && bytes != null) {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      // Ignore errors for now
    } finally {
      if (mounted) _isLoading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.isFastScrolling?.removeListener(_onScrollStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => context.push('/viewer', extra: widget.entity),
        child: Container(
          color: Colors.grey[900],
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_showImage && _bytes != null)
                Image.memory(
                  _bytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                )
              else
                 // Placeholder
                 Container(
                   color: Colors.grey[900],
                 ),
              
              if (widget.entity.type == AssetType.video)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24, width: 1),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 14,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
