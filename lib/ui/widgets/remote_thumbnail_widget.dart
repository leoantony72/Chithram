import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../models/remote_image.dart';
import '../../models/gallery_item.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';
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

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    // Prevent concurrent loads or reload if already loaded
    if (_bytes != null) return;
    
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
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.image_not_supported, color: Colors.white24, size: 20),
        ),
      );
    }

    return GestureDetector(
      onTap: () => context.push('/viewer', extra: GalleryItem.remote(widget.image)),
      child: content,
    );
  }
}
