import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import '../../services/crypto_service.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart';

class AlbumCoverWidget extends StatefulWidget {
  final String thumbUrl;
  final String albumName;

  const AlbumCoverWidget({super.key, required this.thumbUrl, required this.albumName});

  @override
  State<AlbumCoverWidget> createState() => _AlbumCoverWidgetState();
}

class _AlbumCoverWidgetState extends State<AlbumCoverWidget> {
  Uint8List? _bytes;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    if (_bytes != null) return;
    
    if (mounted) setState(() => _isLoading = true);

    try {
      final crypto = CryptoService(); 
      final session = await AuthService().loadSession();
      if (session == null) return;

      final masterKeyBytes = session['masterKey'] as Uint8List;
      final key = SecureKey.fromList(crypto.sodium, masterKeyBytes);

      if (widget.thumbUrl.isNotEmpty) {
        final data = await BackupService().fetchAndDecryptFromUrl(widget.thumbUrl, key);
        if (mounted && data != null) {
          setState(() => _bytes = data);
        }
      }
    } catch (e) {
      debugPrint("Error loading album cover thumb: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return Stack(
         fit: StackFit.expand,
         children: [
            Image.memory(
               _bytes!,
               fit: BoxFit.cover,
               gaplessPlayback: true,
            ),
            Container(
               decoration: const BoxDecoration(
                  gradient: LinearGradient(
                     colors: [Colors.transparent, Colors.black87],
                     begin: Alignment.topCenter,
                     end: Alignment.bottomCenter,
                     stops: [0.6, 1.0],
                  )
               ),
            ),
            Align(
               alignment: Alignment.bottomLeft,
               child: Padding(
                 padding: const EdgeInsets.all(12),
                 child: Text(widget.albumName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, height: 1.1)),
               ),
            )
         ],
      );
    } else {
      return Stack(
         fit: StackFit.expand,
         children: [
            Container(color: Colors.grey[900]),
            Center(
              child: _isLoading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                  : const Icon(Icons.folder, color: Colors.white24, size: 24),
            ),
            Align(
               alignment: Alignment.bottomLeft,
               child: Padding(
                 padding: const EdgeInsets.all(12),
                 child: Text(widget.albumName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, height: 1.1)),
               ),
            )
         ]
      );
    }
  }
}
