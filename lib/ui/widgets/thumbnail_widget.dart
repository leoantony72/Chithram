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

/// How long to wait before starting a thumbnail disk/network load when the
/// scroll position has just stopped. Kept intentionally short so tiles fill
/// in quickly after the user lifts their finger.
const Duration _kThumbnailLoadDefer = Duration(milliseconds: 30);

/// When the grid is being fast-scrolled we skip rendering entirely for this
/// window, then load once scrolling quiets down.
const Duration _kFastScrollBlankDuration = Duration(milliseconds: 180);

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
  Timer? _timer;
  Timer? _loadTimer;

  // ────────────────────────────────────────────────────────────────────────────
  // Selection state is tracked locally (listener pattern) rather than rebuilding
  // every tile via context.select whenever anything in SelectionProvider changes.
  // This is the single biggest rebuild-reduction improvement.
  // ────────────────────────────────────────────────────────────────────────────
  bool _isSelected = false;
  bool _isSelectionMode = false;

  // Hover state via ValueNotifier so only the hover-overlay widget rebuilds,
  // not the entire tile.
  final ValueNotifier<bool> _isHoveringNotifier = ValueNotifier(false);

  SelectionProvider? _selectionProvider;

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newProvider = Provider.of<SelectionProvider>(context, listen: false);
    if (newProvider != _selectionProvider) {
      _selectionProvider?.removeListener(_onSelectionChanged);
      _selectionProvider = newProvider;
      _selectionProvider!.addListener(_onSelectionChanged);
      _syncSelectionState();
    }
  }

  void _syncSelectionState() {
    if (_selectionProvider == null) return;
    final item = _effectiveItem;
    final newIsSelected = _selectionProvider!.isSelected(item);
    final newIsSelectionMode = _selectionProvider!.isSelectionMode;
    if (newIsSelected != _isSelected || newIsSelectionMode != _isSelectionMode) {
      _isSelected = newIsSelected;
      _isSelectionMode = newIsSelectionMode;
    }
  }

  void _onSelectionChanged() {
    if (!mounted) return;
    final item = _effectiveItem;
    final newIsSelected = _selectionProvider!.isSelected(item);
    final newIsSelectionMode = _selectionProvider!.isSelectionMode;
    if (newIsSelected != _isSelected || newIsSelectionMode != _isSelectionMode) {
      setState(() {
        _isSelected = newIsSelected;
        _isSelectionMode = newIsSelectionMode;
      });
    }
  }

  void _checkHighResDiskSync(GalleryItem item) {
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
      _timer = Timer(_kFastScrollBlankDuration, () {
        if (mounted) {
          setState(() => _showImage = true);
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
    // Use addPostFrameCallback for the very first load so we don't block the
    // current frame while tiles are being laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadTimer = Timer(_kThumbnailLoadDefer, () {
        if (mounted) {
          final needsLoad = _bytes == null || (widget.isHighRes && _originFile == null);
          if (needsLoad) _loadThumbnail();
        }
      });
    });
  }

  @override
  void didUpdateWidget(ThumbnailWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentId = _effectiveItem.id;
    final oldId = oldWidget.item?.id ?? oldWidget.entity?.id;

    final currentModLocal = _effectiveItem.local?.modifiedDateSecond;
    final oldEntity = oldWidget.item?.local ?? oldWidget.entity;
    final oldModLocal = oldEntity?.modifiedDateSecond;

    final currentModRemote = _effectiveItem.remote?.modifiedAt;
    final oldModRemote = oldWidget.item?.remote?.modifiedAt;

    final idChanged = currentId != oldId;
    final resChanged = widget.isHighRes != oldWidget.isHighRes;

    final versionChanged = widget.item != null &&
        oldWidget.item != null &&
        widget.item!.version != oldWidget.item!.version;

    bool modChanged = false;
    if (currentModLocal != null && oldModLocal != null && currentModLocal != oldModLocal) {
      modChanged = true;
    } else if (currentModRemote != null &&
        oldModRemote != null &&
        !currentModRemote.isAtSameMomentAs(oldModRemote)) {
      modChanged = true;
    }

    if (idChanged || resChanged || modChanged || versionChanged) {
      _timer?.cancel();
      _loadTimer?.cancel();

      if ((modChanged || versionChanged) && _originFile != null) {
        FileImage(_originFile!).evict();
      }
      if ((modChanged || versionChanged) && _bytes != null) {
        PaintingBinding.instance.imageCache.evict(MemoryImage(_bytes!));
      }

      _originFile = null;
      _isLoading = false;

      if (idChanged || modChanged) {
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
        setState(() => _showImage = true);
        if (_bytes == null || widget.isHighRes) _scheduleLoad();
      }
    }
  }

  Future<void> _loadThumbnail() async {
    if (_originFile != null) return;
    if (!widget.isHighRes && _bytes != null) return;
    if (_isLoading) return;

    _isLoading = true;

    final item = _effectiveItem;

    // LOCAL ASSET MAPPING (High-Res optimization)
    AssetEntity? localMapped;
    if (widget.isHighRes &&
        item.type == GalleryItemType.remote &&
        item.remote?.sourceId != null) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      localMapped = provider.findLocalAssetById(item.remote!.sourceId!);
    }

    if (item.type == GalleryItemType.local || localMapped != null) {
      final entity = localMapped ?? item.local!;
      if (widget.isHighRes) {
        try {
          if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
            final convertedFile = await ThumbnailCache().getConvertedHighResFile(entity);
            if (mounted && convertedFile != null && await convertedFile.exists()) {
              setState(() => _originFile = convertedFile);
              return;
            }

            final file = await entity.originFile;
            if (file != null && await file.exists()) {
              final ext = file.path.toLowerCase();
              if (!ext.endsWith('.heic') &&
                  !ext.endsWith('.heif') &&
                  !ext.endsWith('.raw') &&
                  !ext.endsWith('.dng')) {
                if (mounted) setState(() => _originFile = file);
                return;
              }
            }
          }

          final bytes = await entity.thumbnailDataWithSize(
            const ThumbnailSize.square(2000),
            quality: 95,
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

        if (widget.isHighRes) {
          final cachedFile = await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
          if (cachedFile != null && await cachedFile.exists()) {
            if (mounted) setState(() => _originFile = cachedFile);
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
        bool isActualHighRes = false;

        if (widget.isHighRes) {
          final isWindowsOrLinux =
              !kIsWeb && (Platform.isWindows || Platform.isLinux);
          final isHeicOriginal =
              remote.mimeType.contains('heic') || remote.mimeType.contains('heif');

          if (isWindowsOrLinux && isHeicOriginal) {
            if (remote.thumb1024Url.isNotEmpty) {
              url = remote.thumb1024Url;
              isActualHighRes = true;
            } else if (remote.thumb256Url.isNotEmpty) {
              url = remote.thumb256Url;
              isActualHighRes = true;
            } else {
              url = remote.thumb64Url;
              isActualHighRes = true;
            }
          } else if (remote.originalUrl.isNotEmpty) {
            url = remote.originalUrl;
            isActualHighRes = true;
          } else if (remote.thumb1024Url.isNotEmpty) {
            url = remote.thumb1024Url;
            isActualHighRes = true;
          }
        }

        if (url.isNotEmpty) {
          final data = await BackupService().fetchAndDecryptFromUrl(url, key);
          if (mounted && data != null) {
            if (widget.isHighRes && isActualHighRes) {
              await ThumbnailCache().saveRemoteOriginalFile(remote.imageId, data);
              var cachedFile =
                  await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
              if (cachedFile == null &&
                  !kIsWeb &&
                  (Platform.isWindows || Platform.isLinux) &&
                  (remote.mimeType.contains('heic') ||
                      remote.mimeType.contains('heif'))) {
                final fallbackUrl = remote.thumb1024Url.isNotEmpty
                    ? remote.thumb1024Url
                    : (remote.thumb256Url.isNotEmpty
                        ? remote.thumb256Url
                        : remote.thumb64Url);
                if (fallbackUrl.isNotEmpty) {
                  final jpegData =
                      await BackupService().fetchAndDecryptFromUrl(fallbackUrl, key);
                  if (mounted && jpegData != null && jpegData.isNotEmpty) {
                    await ThumbnailCache()
                        .saveRemoteJpegFallback(remote.imageId, jpegData);
                    cachedFile =
                        await ThumbnailCache().getRemoteOriginalFile(remote.imageId);
                  }
                }
              }
              if (mounted && cachedFile != null) {
                setState(() => _originFile = cachedFile);
                return;
              }
              if (!kIsWeb &&
                  (Platform.isWindows || Platform.isLinux) &&
                  (remote.mimeType.contains('heic') ||
                      remote.mimeType.contains('heif'))) {
                if (mounted) setState(() => _bytes = null);
                return;
              }
            } else {
              ThumbnailCache().putMemory(remote.imageId, data);
            }
            if (mounted) setState(() => _bytes = data);
          }
        }
      } catch (e) {
        debugPrint("Error loading remote thumb: $e");
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
    _selectionProvider?.removeListener(_onSelectionChanged);
    _isHoveringNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = _effectiveItem;
    final heroTag =
        '${widget.heroTagPrefix ?? 'thumb'}_${item.id}';

    Widget imageContent;
    if (!_showImage) {
      // During fast-scroll: render nothing (plain colour box is cheapest)
      imageContent = const ColoredBox(color: Color(0xFF1A1A1A));
    } else if (_originFile != null) {
      imageContent = Image.file(
        _originFile!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stackTrace) {
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
        onEnter: (_) => _isHoveringNotifier.value = true,
        onExit: (_) => _isHoveringNotifier.value = false,
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (_isSelectionMode) {
              _selectionProvider?.toggleSelection(item);
            } else if (widget.onTap != null) {
              widget.onTap!();
            } else {
              context.push('/viewer', extra: item);
            }
          },
          onSecondaryTap: () => _selectionProvider?.toggleSelection(item),
          onLongPress: () => _selectionProvider?.toggleSelection(item),
          child: ClipRRect(
            // Fixed 4px radius — no animation on radius change so no per-frame
            // ClipRRect recompute cost on every selection toggle.
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 1 — Image (with selection inset via Padding)
                _isSelected
                    ? Padding(
                        padding: const EdgeInsets.all(6.0),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: imageContent,
                        ),
                      )
                    : imageContent,

                // 2 — Darkening overlay when selected
                if (_isSelected)
                  const ColoredBox(color: Color(0x33000000)),

                // 3 — Video duration badge
                if (item.duration.inSeconds > 0 || 
                    (item.type == GalleryItemType.local && (item.local!.type == AssetType.video || item.local!.typeInt == 2)) ||
                    (item.type == GalleryItemType.remote && (item.remote?.mimeType?.startsWith('video/') ?? false)))
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _VideoBadge(duration: item.duration),
                  ),

                // 4 — Selection checkmark
                if (_isSelected)
                  const Positioned(
                    top: 8,
                    left: 8,
                    child: Icon(
                      Icons.check_circle,
                      color: Colors.blueAccent,
                      size: 22,
                    ),
                  ),

                // 5 — Hover "select" circle — only this rebuilds on hover,
                //     not the whole tile, thanks to ValueListenableBuilder.
                if (!_isSelected)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _isHoveringNotifier,
                      builder: (context, isHovering, _) {
                        if (!isHovering) return const SizedBox.shrink();
                        return GestureDetector(
                          onTap: () => _selectionProvider?.toggleSelection(item),
                          child: const Icon(
                            Icons.circle_outlined,
                            color: Colors.white70,
                            size: 22,
                          ),
                        );
                      },
                    ),
                  ),

                // 6 — Favourite heart
                if (item.isFavorite)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Icon(
                      Icons.favorite,
                      color: Colors.redAccent.withOpacity(0.85),
                      size: 14,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    // Simple solid box — no CircularProgressIndicator to avoid per-frame
    // animation cost on every unloaded tile during scrolling.
    return const ColoredBox(color: Color(0xFF1A1A1A));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Extracted stateless widget for video duration badge to keep the main
// build() method slim and avoid unnecessary SubtreeKey changes.
// ─────────────────────────────────────────────────────────────────────────────
class _VideoBadge extends StatelessWidget {
  final Duration duration;
  const _VideoBadge({required this.duration});

  @override
  Widget build(BuildContext context) {
    final label = _formatDuration(duration);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 2)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 16),
          if (label.isNotEmpty) ...[
            const SizedBox(width: 2),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inSeconds == 0) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    final mins = two(d.inMinutes.remainder(60));
    final secs = two(d.inSeconds.remainder(60));
    if (d.inHours > 0) return '${d.inHours}:$mins:$secs';
    return '$mins:$secs';
  }
}
