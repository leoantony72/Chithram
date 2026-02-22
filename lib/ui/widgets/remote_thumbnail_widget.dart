import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../../providers/selection_provider.dart';
import '../../models/remote_image.dart';
import '../../models/gallery_item.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';
import '../../services/thumbnail_cache.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

class RemoteThumbnailWidget extends StatefulWidget {
  final RemoteImage image;

  const RemoteThumbnailWidget({super.key, required this.image});

  @override
  State<RemoteThumbnailWidget> createState() => _RemoteThumbnailWidgetState();
}

class _RemoteThumbnailWidgetState extends State<RemoteThumbnailWidget> {
  Uint8List? _bytes;
  bool _isLoading = false;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    // Prevent concurrent loads or reload if already loaded
    if (_bytes != null) return;
    
    final cached = ThumbnailCache().getMemory(widget.image.imageId);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }

    if (mounted) setState(() => _isLoading = true);

    try {
      final crypto = CryptoService(); 
      // Ensure sodium is initialized
      // In a real app, this should be guaranteed by main.dart or a provider
      
      final session = await AuthService().loadSession();
      if (session == null) return;

      final masterKeyBytes = session['masterKey'] as Uint8List;
      
      // We need to re-derive/hydrate key. 
      final key = SecureKey.fromList(crypto.sodium, masterKeyBytes);

      // Prefer 256 thumb, fallback to 64
      var url = widget.image.thumb256Url;
      if (url.isEmpty) url = widget.image.thumb64Url;

      if (url.isNotEmpty) {
        final data = await BackupService().fetchAndDecryptFromUrl(url, key);
        if (mounted && data != null) {
          ThumbnailCache().putMemory(widget.image.imageId, data);
          setState(() => _bytes = data);
        }
      }
    } catch (e) {
      debugPrint("Error loading remote thumb: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (_bytes != null) {
      content = Image.memory(
        _bytes!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    } else {
      content = Container(
        color: Colors.grey[900],
        child: Center(
          child: _isLoading 
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
              : const Icon(Icons.image_not_supported, color: Colors.white24, size: 20),
        ),
      );
    }

    final item = GalleryItem.remote(widget.image);

    return Consumer<SelectionProvider>(
      builder: (context, selection, child) {
        final isSelected = selection.isSelected(item);
        final isSelectionMode = selection.isSelectionMode;

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() => _isHovering = false),
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              if (isSelectionMode) {
                selection.toggleSelection(item);
              } else {
                context.push('/viewer', extra: item);
              }
            },
            onLongPress: () {
              selection.toggleSelection(item);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              padding: isSelected ? const EdgeInsets.all(8.0) : EdgeInsets.zero,
              decoration: BoxDecoration(
                color: isSelected ? Colors.grey[800] : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(isSelected ? 4 : 6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    content,
                    if (_isHovering || isSelected)
                      Positioned(
                        top: 6,
                        left: 6,
                        child: GestureDetector(
                          onTap: () => selection.toggleSelection(item),
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: isSelected ? Colors.blue : Colors.white.withOpacity(0.5),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: isSelected
                                ? const Icon(Icons.check, color: Colors.white, size: 14)
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
