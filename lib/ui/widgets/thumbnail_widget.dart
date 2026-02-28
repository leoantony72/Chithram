import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/selection_provider.dart';
import '../../services/thumbnail_cache.dart';
import '../../models/gallery_item.dart';

class ThumbnailWidget extends StatefulWidget {
  final AssetEntity entity;
  final ValueListenable<bool>? isFastScrolling;
  final String? heroTagPrefix;
  final VoidCallback? onTap;
  final bool isHighRes;
  
  const ThumbnailWidget({
    super.key, 
    required this.entity,
    this.isFastScrolling,
    this.heroTagPrefix,
    this.onTap,
    this.isHighRes = false,
  });

  @override
  State<ThumbnailWidget> createState() => _ThumbnailWidgetState();
}

class _ThumbnailWidgetState extends State<ThumbnailWidget> {
  Uint8List? _bytes;
  File? _originFile;
  bool _isLoading = false;
  bool _showImage = true;
  bool _isHovering = false;
  Timer? _timer;
  Timer? _loadTimer;

  @override
  void initState() {
    super.initState();
    _bytes = ThumbnailCache().getMemory(widget.entity.id);
    _initShowState();
    
    if (widget.isFastScrolling != null) {
      widget.isFastScrolling!.addListener(_onScrollStateChanged);
    }
  }

  void _initShowState() {
    if (widget.isFastScrolling?.value == true) {
      _showImage = false;
      _timer = Timer(const Duration(milliseconds: 150), () {
        if (mounted) {
           setState(() {
             _showImage = true;
           });
           if (_bytes == null) _scheduleLoad();
        }
      });
    } else {
      _showImage = true;
      if (_bytes == null) _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(milliseconds: 50), () {
       if (mounted && _bytes == null) {
          _loadThumbnail();
       }
    });
  }

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.entity.id != oldWidget.entity.id) {
       _timer?.cancel();
       _loadTimer?.cancel();
       _originFile = null;
       _bytes = ThumbnailCache().getMemory(widget.entity.id);
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
        if (_bytes == null) _scheduleLoad();
      }
    }
  }

  Future<void> _loadThumbnail() async {
    if (_bytes != null || _originFile != null) return;
    if (_isLoading) return;
    
    _isLoading = true;

    if (widget.isHighRes) {
       try {
         if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
            final file = await widget.entity.originFile;
            if (file != null && await file.exists()) {
               final ext = file.path.toLowerCase();
               if (!ext.endsWith('.heic') && !ext.endsWith('.heif') && !ext.endsWith('.raw') && !ext.endsWith('.dng')) {
                  if (mounted) setState(() => _originFile = file);
                  return;
               } else {
                  final convertedFile = await ThumbnailCache().getConvertedHighResFile(widget.entity);
                  if (mounted && convertedFile != null && await convertedFile.exists()) {
                     setState(() => _originFile = convertedFile);
                     return;
                  }
               }
            }
         }

         final bytes = await widget.entity.thumbnailDataWithSize(
            const ThumbnailSize.square(1000), 
            quality: 100 
         );
         
         if (mounted && bytes != null && bytes.isNotEmpty) {
            setState(() => _bytes = bytes);
         }
       } catch (e) {
          debugPrint("Error loading high-res thumbnail: $e");
       } finally {
         if (mounted) setState(() => _isLoading = false);
       }
    } else {
       // Standard grid requests hit the ThumbnailCache asynchronously
       try {
         final bytes = await ThumbnailCache().getThumbnail(widget.entity);
         if (mounted && bytes != null) {
            setState(() => _bytes = bytes);
         }
       } catch (e) {
         debugPrint("Error getting cached thumbnail: $e");
       } finally {
         if (mounted) setState(() => _isLoading = false);
       }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _loadTimer?.cancel();
    widget.isFastScrolling?.removeListener(_onScrollStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = GalleryItem.local(widget.entity);
    // Use `context.select` to only rebuild this specific widget when ITS selection state changes.
    // Extremely lightweight compared to a full Consumer tree.
    final isSelected = context.select<SelectionProvider, bool>((s) => s.isSelected(item));
    final isSelectionMode = context.select<SelectionProvider, bool>((s) => s.isSelectionMode);

    Widget imageContent;
    if (widget.isHighRes) {
      if (_originFile != null) {
        imageContent = Image.file(
           _originFile!, 
           fit: BoxFit.cover, 
           gaplessPlayback: true,
           errorBuilder: (context, error, stackTrace) {
              debugPrint("Image.file codec error: $error");
              return Container(
                 color: Colors.grey[900],
                 child: const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 32)),
              );
           },
        );
      } else if (_bytes != null && _bytes!.isNotEmpty) {
        imageContent = Image.memory(
           _bytes!, 
           fit: BoxFit.cover, 
           gaplessPlayback: true,
           errorBuilder: (context, error, stackTrace) {
              debugPrint("Image.memory codec error: $error");
              return Container(
                 color: Colors.grey[900],
                 child: const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 32)),
              );
           },
        );
      } else {
        imageContent = Container(color: Colors.grey[900]);
      }
    } else {
      if (_bytes != null && _bytes!.isNotEmpty) {
        imageContent = Image.memory(
           _bytes!, 
           fit: BoxFit.cover, 
           gaplessPlayback: true,
           errorBuilder: (context, error, stackTrace) {
              debugPrint("Image.memory codec error: $error");
              return Container(
                 color: Colors.grey[900],
                 child: const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 32)),
              );
           },
        );
      } else if (_showImage) {
        // Fallback loading state before bytes return from cache
        imageContent = Container(color: Colors.grey[900]); 
      } else {
        // Fast scrolling proxy
        imageContent = Container(color: Colors.grey[900]);
      }
    }

    return RepaintBoundary(
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (isSelectionMode) {
              context.read<SelectionProvider>().toggleSelection(item);
            } else if (widget.onTap != null) {
              widget.onTap!();
            } else {
              context.push('/viewer', extra: item);
            }
          },
          onLongPress: () {
            context.read<SelectionProvider>().toggleSelection(item);
          },
          // Minimal static layouts instead of AnimatedContainer
          child: Padding(
            padding: isSelected ? const EdgeInsets.all(8.0) : EdgeInsets.zero,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(isSelected ? 4 : 6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    color: Colors.grey[900],
                    child: imageContent,
                  ),
                  
                  if (widget.entity.type == AssetType.video)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatDuration(widget.entity.videoDuration),
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),

                  if (isSelected)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.3),
                        child: const Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Icon(Icons.check_circle, color: Colors.blueAccent, size: 24),
                          ),
                        ),
                      ),
                    ),
                    
                   if (!isSelected && _isHovering)
                     const Positioned(
                        top: 8,
                        left: 8,
                        child: Icon(Icons.circle_outlined, color: Colors.white70, size: 24),
                     ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDuration(Duration duration) {
    if (duration.inSeconds == 0) return '';
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${duration.inHours}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }
}
