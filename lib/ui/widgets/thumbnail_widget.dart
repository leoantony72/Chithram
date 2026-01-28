import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import '../../services/thumbnail_cache.dart';

class ThumbnailWidget extends StatefulWidget {
  final AssetEntity entity;
  
  const ThumbnailWidget({super.key, required this.entity});

  @override
  State<ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<ThumbnailWidget> {
  Uint8List? _bytes;
  Timer? _debounceTimer;
  
  @override
  void initState() {
    super.initState();
    // Synchronous check for instant rendering (crucial for smooth zoom swaps)
    _bytes = ThumbnailCache().getMemory(widget.entity.id);
    if (_bytes == null) {
      _loadThumbnail();
    }
  }
  
  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entity.id != oldWidget.entity.id) {
      _loadThumbnail();
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadThumbnail() async {
    _debounceTimer?.cancel();
    
    // Check memory again (useful for updates)
    final cachedBytes = ThumbnailCache().getMemory(widget.entity.id);
    if (cachedBytes != null) {
      if (mounted) {
        setState(() {
          _bytes = cachedBytes;
          _hasError = false;
        });
      }
      return; 
    }

    // Clear previous if recycling and not in Cache
    if (mounted && _bytes != null) {
      setState(() {
        _bytes = null;
      });
    }

    // 2. Check Disk Index (Fast, Synchronous)
    if (ThumbnailCache().hasInDisk(widget.entity.id)) {
       _loadFromCacheOrGen();
       return; 
    }

    // Debounce: Wait 150ms. If user scrolls past this cell, 
    // dispose() will cancel timer, or next didUpdateWidget will cancel it.
    // This prevents firing thousands of native calls during fast scroll.
    _debounceTimer = Timer(const Duration(milliseconds: 150), () {
        _loadFromCacheOrGen();
    });
  }
  
  bool _hasError = false;

  Future<void> _loadFromCacheOrGen() async {
      try {
        if (!mounted) return;
        
        final bytes = await ThumbnailCache().getThumbnail(widget.entity);
        
        if (mounted && bytes != null) {
          setState(() {
            _bytes = bytes;
            _hasError = false;
          });
        } else if (mounted) {
           // If bytes is null (likely permission or file IO issue), treat as error
           setState(() {
              _hasError = true;
           });
        }
      } catch (e) {
        // debugPrint("Error loading thumbnail for ${widget.entity.id}: $e"); 
        // Suppressed to avoid log spam for corrupt videos
        if (mounted) {
           setState(() {
              _bytes = null;
              _hasError = true;
           });
        }
      }
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onTap: () => context.push('/viewer', extra: widget.entity),
        child: Hero(
        tag: widget.entity.id,
        child: Container(
          color: Colors.grey[900],
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_bytes != null)
                Image.memory(
                  _bytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                )
              else
                 Container(
                   color: Colors.grey[900],
                   child: Center(
                     child: _hasError 
                       ? Icon(Icons.broken_image, color: Colors.white24, size: 20)
                       : const SizedBox.shrink(), // Empty while loading/debouncing
                   ),
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
    ),
  );
  }
}
