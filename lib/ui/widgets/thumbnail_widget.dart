import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/selection_provider.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';
import '../../services/thumbnail_cache.dart';
import '../../services/crypto_service.dart';
import '../../services/auth_service.dart';
import '../../services/backup_service.dart';
import '../../models/gallery_item.dart';

class ThumbnailWidget extends StatefulWidget {
  final AssetEntity? entity;
  final GalleryItem? item;
  final ValueListenable<bool>? isFastScrolling;
  final String? heroTagPrefix;
  final VoidCallback? onTap;
  final bool isHighRes;
  
  const ThumbnailWidget({
    super.key, 
    this.entity,
    this.item,
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

  GalleryItem get _effectiveItem {
    if (widget.item != null) return widget.item!;
    return GalleryItem.local(widget.entity!);
  }

  @override
  void initState() {
    super.initState();
    final id = _effectiveItem.id;
    _bytes = ThumbnailCache().getMemory(id);
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
    if (_effectiveItem.id != (oldWidget.item?.id ?? oldWidget.entity?.id)) {
       _timer?.cancel();
       _loadTimer?.cancel();
       _originFile = null;
       _bytes = ThumbnailCache().getMemory(_effectiveItem.id);
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

    final item = _effectiveItem;

    if (item.type == GalleryItemType.local) {
      final entity = item.local!;
      if (widget.isHighRes) {
         try {
           if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              final file = await entity.originFile;
              if (file != null && await file.exists()) {
                 final ext = file.path.toLowerCase();
                 if (!ext.endsWith('.heic') && !ext.endsWith('.heif') && !ext.endsWith('.raw') && !ext.endsWith('.dng')) {
                    if (mounted) setState(() => _originFile = file);
                    return;
                 } else {
                    final convertedFile = await ThumbnailCache().getConvertedHighResFile(entity);
                    if (mounted && convertedFile != null && await convertedFile.exists()) {
                       setState(() => _originFile = convertedFile);
                       return;
                    }
                 }
              }
           }

           final bytes = await entity.thumbnailDataWithSize(
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
         try {
           final bytes = await ThumbnailCache().getThumbnail(entity);
           if (mounted && bytes != null) {
              setState(() => _bytes = bytes);
           }
         } catch (e) {
           debugPrint("Error getting cached thumbnail: $e");
         } finally {
           if (mounted) setState(() => _isLoading = false);
         }
      }
    } else {
      // Remote Loading Logic
      try {
        final remote = item.remote!;
        final crypto = CryptoService(); 
        final session = await AuthService().loadSession();
        if (session == null) return;

        final masterKeyBytes = session['masterKey'] as Uint8List;
        final key = SecureKey.fromList(crypto.sodium, masterKeyBytes);

        var url = remote.thumb256Url;
        if (url.isEmpty) url = remote.thumb64Url;

        if (widget.isHighRes && remote.originalUrl.isNotEmpty) {
            url = remote.originalUrl;
        }

        if (url.isNotEmpty) {
          final data = await BackupService().fetchAndDecryptFromUrl(url, key);
          if (mounted && data != null) {
            if (!widget.isHighRes) {
               ThumbnailCache().putMemory(remote.imageId, data);
            }
            setState(() => _bytes = data);
          }
        }
      } catch (e) {
        debugPrint("Error loading remote thumb in unified widget: $e");
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
    final item = _effectiveItem;
    final isSelected = context.select<SelectionProvider, bool>((s) => s.isSelected(item));
    final isSelectionMode = context.select<SelectionProvider, bool>((s) => s.isSelectionMode);

    Widget imageContent;
    if (_originFile != null) {
      imageContent = Image.file(
         _originFile!, 
         fit: BoxFit.cover, 
         gaplessPlayback: true,
         errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    } else if (_bytes != null && _bytes!.isNotEmpty) {
      imageContent = Image.memory(
         _bytes!, 
         fit: BoxFit.cover, 
         gaplessPlayback: true,
         errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    } else {
      imageContent = _buildPlaceholder();
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
                  
                  if (item.type == GalleryItemType.local && item.local!.type == AssetType.video)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.5),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _formatDuration(item.local!.videoDuration),
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),

                  if (isSelected)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withOpacity(0.3),
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

                   if (item.isFavorite)
                     Positioned(
                       bottom: 8,
                       right: 8,
                       child: Icon(Icons.favorite, color: Colors.redAccent.withOpacity(0.8), size: 16),
                     ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: Colors.grey[900],
      child: Center(
        child: _isLoading 
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white24))
            : const Icon(Icons.image, color: Colors.white10, size: 32),
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
