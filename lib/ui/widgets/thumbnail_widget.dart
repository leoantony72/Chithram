import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/photo_provider.dart';
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
    final item = _effectiveItem;
    _bytes = ThumbnailCache().getMemory(item.id);
    
    // Proactive High-Res Disk Check
    if (widget.isHighRes) {
       _checkHighResDiskSync(item);
    }

    _initShowState();
    
    if (widget.isFastScrolling != null) {
      widget.isFastScrolling!.addListener(_onScrollStateChanged);
    }
  }

  void _checkHighResDiskSync(GalleryItem item) {
    // We can't await in initState, but we can check if the file exists on disk synchronously-ish or via then
    if (item.type == GalleryItemType.local) {
       ThumbnailCache().getConvertedHighResFile(item.local!).then((file) {
          if (mounted && file != null && file.existsSync()) {
             setState(() => _originFile = file);
          }
       });
    } else {
       ThumbnailCache().getRemoteOriginalFile(item.remote!.imageId).then((file) {
          if (mounted && file != null && file.existsSync()) {
             setState(() => _originFile = file);
          }
       });
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
            if (_bytes == null || widget.isHighRes) _scheduleLoad();
        }
      });
    } else {
      _showImage = true;
      if (_bytes == null || widget.isHighRes) _scheduleLoad();
    }
  }

  void _scheduleLoad() {
    _loadTimer?.cancel();
    _loadTimer = Timer(const Duration(milliseconds: 50), () {
       if (mounted) {
          // Always run _loadThumbnail if there is no image data at all.
          // Also run if this is a high-res slot but we haven't fetched the high-res file yet.
          final needsLoad = _bytes == null || (widget.isHighRes && _originFile == null);
          if (needsLoad) {
             _loadThumbnail();
          }
       }
    });
  }

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentId = _effectiveItem.id;
    final oldId = oldWidget.item?.id ?? oldWidget.entity?.id;
    
    if (currentId != oldId || widget.isHighRes != oldWidget.isHighRes) {
       _timer?.cancel();
       _loadTimer?.cancel();
       _originFile = null;
       
       if (currentId != oldId) {
          _bytes = ThumbnailCache().getMemory(currentId);
       }

       if (widget.isHighRes) {
          _checkHighResDiskSync(_effectiveItem);
       }

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
        if (_bytes == null || widget.isHighRes) _scheduleLoad();
      }
    }
  }

  Future<void> _loadThumbnail() async {
    // If a high-res file is already displayed, nothing to do.
    if (_originFile != null) return;
    // For non-high-res, if we already have bytes, nothing to do.
    if (!widget.isHighRes && _bytes != null) return;
    if (_isLoading) return;
    
    _isLoading = true;

    final item = _effectiveItem;
    
    // --- LOCAL ASSET MAPPING (High-Res optimization) ---
    // If this is a remote item but it originated from THIS device (sourceId),
    // try to find the local asset and use its high-res data instead of cloud HEIC.
    AssetEntity? localMapped;
    if (widget.isHighRes && item.type == GalleryItemType.remote && item.remote?.sourceId != null) {
       final provider = Provider.of<PhotoProvider>(context, listen: false);
       localMapped = provider.findLocalAssetById(item.remote!.sourceId!);
       if (localMapped != null) {
          debugPrint("ThumbnailWidget: Local Mapping Hit for Remote ${item.id} -> Local ${localMapped.id}");
       }
    }

    if (item.type == GalleryItemType.local || localMapped != null) {
      final entity = localMapped ?? item.local!;
      if (widget.isHighRes) {
         try {
           if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
              final convertedFile = await ThumbnailCache().getConvertedHighResFile(entity);
              if (mounted && convertedFile != null && await convertedFile.exists()) {
                 debugPrint("ThumbnailWidget: Local High-Res Hit (Converted) -> ${convertedFile.path}");
                 setState(() {
                    _originFile = convertedFile;
                    // Don't clear _bytes; use as fallback if Image.file fails
                 });
                 return;
              }
              
              final file = await entity.originFile;
              if (file != null && await file.exists()) {
                 final ext = file.path.toLowerCase();
                 if (!ext.endsWith('.heic') && !ext.endsWith('.heif') && !ext.endsWith('.raw') && !ext.endsWith('.dng')) {
                    debugPrint("ThumbnailWidget: Local High-Res Hit (Origin) -> ${file.path}");
                    if (mounted) setState(() {
                       _originFile = file;
                       // Don't clear _bytes; use as fallback if Image.file fails
                    });
                    return;
                 }
              }
           }

           // Fallback to large thumb if origin/converted fails
           debugPrint("ThumbnailWidget: Local High-Res Fallback (2000px) Request for ${item.id}");
           final bytes = await entity.thumbnailDataWithSize(
              const ThumbnailSize.square(2000), 
              quality: 95 
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
        
        // --- High-Res Disk Cache Check ---
        if (widget.isHighRes) {
           final cachedFile = await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
           if (cachedFile != null && await cachedFile.exists()) {
              debugPrint("ThumbnailWidget: Remote High-Res Disk Hit -> ${cachedFile.path}");
              if (mounted) setState(() {
                 _originFile = cachedFile;
                 // Don't clear _bytes; use as fallback if Image.file fails
              });
              return;
           }
        }

        final crypto = CryptoService(); 
        final session = await AuthService().loadSession();
        if (session == null) return;

        final masterKeyBytes = session['masterKey'] as Uint8List;
        final key = SecureKey.fromList(crypto.sodium, masterKeyBytes);

        var url = remote.thumb256Url;
        if (url.isEmpty) url = remote.thumb64Url;
        bool _isActualHighRes = false; // Tracks if we're fetching real high-res data

        // Use high-res source for cards (Journeys, etc)
        if (widget.isHighRes) {
            final isWindowsOrLinux = Platform.isWindows || Platform.isLinux;
            final isHeicOriginal = remote.mimeType.contains('heic') || remote.mimeType.contains('heif');
            
            if (isWindowsOrLinux && isHeicOriginal) {
                // Windows cannot decode HEIC. Use best available JPEG: 1024px > 256px > 64px.
                // Never download HEIC original - conversion always fails.
                if (remote.thumb1024Url.isNotEmpty) {
                    url = remote.thumb1024Url;
                    _isActualHighRes = true;
                    debugPrint("ThumbnailWidget: Using 1024px JPEG for Windows HEIC (sharp) -> $url");
                } else if (remote.thumb256Url.isNotEmpty) {
                    url = remote.thumb256Url;
                    _isActualHighRes = true;
                    debugPrint("ThumbnailWidget: Using 256px JPEG for Windows HEIC (legacy, no 1024) -> $url");
                } else {
                    url = remote.thumb64Url;
                    _isActualHighRes = true;
                }
            } else if (remote.originalUrl.isNotEmpty) {
                url = remote.originalUrl;
                _isActualHighRes = true;
                debugPrint("ThumbnailWidget: Fetching Remote Original URL -> $url");
            } else if (remote.thumb1024Url.isNotEmpty) {
                url = remote.thumb1024Url;
                _isActualHighRes = true;
            }
        }

        if (url.isNotEmpty) {
          final data = await BackupService().fetchAndDecryptFromUrl(url, key);
          if (mounted && data != null) {
            if (widget.isHighRes && _isActualHighRes) {
               debugPrint("ThumbnailWidget: Successfully decrypted high-res. Saving to disk...");
               // --- Save to High-Res Disk Cache (only genuine high-res content) ---
               await ThumbnailCache().saveRemoteOriginalFile(remote.imageId, data);
               // Re-fetch to use as File (more RAM efficient than bytes for large cards)
               var cachedFile = await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
               // Windows HEIC fix: image package cannot decode HEIC. If conversion failed,
               // fall back to thumb1024 or thumb256 (JPEG) and save as cover.
               if (cachedFile == null &&
                   (Platform.isWindows || Platform.isLinux) &&
                   (remote.mimeType.contains('heic') || remote.mimeType.contains('heif'))) {
                  debugPrint("ThumbnailWidget: HEIC conversion failed on Windows. Using JPEG thumbnail fallback.");
                  final fallbackUrl = remote.thumb1024Url.isNotEmpty
                      ? remote.thumb1024Url
                      : (remote.thumb256Url.isNotEmpty ? remote.thumb256Url : remote.thumb64Url);
                  if (fallbackUrl.isNotEmpty) {
                    final jpegData = await BackupService().fetchAndDecryptFromUrl(fallbackUrl, key);
                    if (mounted && jpegData != null && jpegData.isNotEmpty) {
                      await ThumbnailCache().saveRemoteJpegFallback(remote.imageId, jpegData);
                      cachedFile = await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
                    }
                  }
               }
               if (mounted && cachedFile != null) {
                  setState(() {
                     _originFile = cachedFile;
                  });
                  return;
               }
               // If we still have no file but have HEIC bytes, don't use Image.memory(heic) - it fails on Windows
               if ((Platform.isWindows || Platform.isLinux) &&
                   (remote.mimeType.contains('heic') || remote.mimeType.contains('heif'))) {
                  // Already tried fallback above; if we're here, fallback also failed - show placeholder
                  setState(() => _bytes = null);
                  return;
               }
            } else {
               // Low-res fallback or non-high-res: show in memory only, don't persist as high-res
               ThumbnailCache().putMemory(remote.imageId, data);
            }
            setState(() => _bytes = data);
          } else if (mounted && data == null) {
             debugPrint("ThumbnailWidget: Failed to fetch/decrypt URL -> $url");
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
    
    // Consolidate selectors to minimize build evaluations
    final selectionState = context.select<SelectionProvider, ({bool isSelected, bool isSelectionMode})>(
      (s) => (isSelected: s.isSelected(item), isSelectionMode: s.isSelectionMode)
    );
    final isSelected = selectionState.isSelected;
    final isSelectionMode = selectionState.isSelectionMode;

    Widget imageContent;
    if (_originFile != null) {
      imageContent = Image.file(
         _originFile!, 
         fit: BoxFit.cover, 
         gaplessPlayback: true,
         errorBuilder: (context, error, stackTrace) {
            debugPrint("ThumbnailWidget: Image.file error for ${_originFile!.path}: $error. Falling back to thumbnail bytes.");
            // Log if it's HEIC
            if (_originFile!.path.toLowerCase().endsWith('.heic') || _originFile!.path.toLowerCase().endsWith('.heif')) {
               debugPrint("ThumbnailWidget: File is HEIC/HEIF - Not natively supported on Windows Flutter.");
            }
            if (_bytes != null && _bytes!.isNotEmpty) {
               return Image.memory(_bytes!, fit: BoxFit.cover, gaplessPlayback: true);
            }
            return _buildPlaceholder();
         },
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
          onDoubleTap: () {
             // Optional: Explicitly open viewer on double tap even if in selection mode?
             // Not requested, keeping simple for now.
          },
          onSecondaryTap: () {
             // Right Click to Select
             context.read<SelectionProvider>().toggleSelection(item);
          },
          onLongPress: () {
            context.read<SelectionProvider>().toggleSelection(item);
          },
          child: AnimatedPadding(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
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
                     Positioned(
                        top: 8,
                        left: 8,
                        child: GestureDetector(
                           onTap: () {
                              context.read<SelectionProvider>().toggleSelection(item);
                           },
                           child: const Icon(Icons.circle_outlined, color: Colors.white70, size: 24),
                        ),
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
