import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:extended_image/extended_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/share_service.dart';
import '../../services/backup_service.dart';

class SharedViewerPage extends StatefulWidget {
  final Uint8List bytes;
  final ShareItem share;
  final String senderUsername;

  const SharedViewerPage({
    super.key,
    required this.bytes,
    required this.share,
    required this.senderUsername,
  });

  @override
  State<SharedViewerPage> createState() => _SharedViewerPageState();
}

class _SharedViewerPageState extends State<SharedViewerPage> {
  bool _isSaving = false;
  bool _isAddingToCloud = false;
  bool _isDeleting = false;

  Future<void> _downloadImage() async {
    setState(() => _isSaving = true);
    try {
      if (Platform.isWindows) {
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final result = await FilePicker.platform.saveFile(
          dialogTitle: 'SAVE SHARED PHOTO',
          fileName: 'ninta_shared_$timestamp.jpg',
          type: FileType.image,
        );

        if (result != null) {
          final file = File(result);
          await file.writeAsBytes(widget.bytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('SAVED SUCCESSFULLY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                backgroundColor: Color(0xFF1A1A1A),
                behavior: SnackBarBehavior.floating,
              ),
            );
          }
        }
      } else if (Platform.isAndroid) {
        if (await Permission.storage.request().isDenied && await Permission.photos.request().isDenied) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('STORAGE PERMISSION DENIED')),
            );
          }
          return;
        }

        // Target Android Downloads folder
        const downloadsPath = '/storage/emulated/0/Download';
        final dir = Directory(downloadsPath);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('$downloadsPath/ninta_shared_$timestamp.jpg');
        await file.writeAsBytes(widget.bytes);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('SAVED TO DOWNLOADS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              backgroundColor: Color(0xFF1A1A1A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      } else {
        // Fallback for other platforms
        final directory = await getApplicationDocumentsDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final file = File('${directory.path}/ninta_shared_$timestamp.jpg');
        await file.writeAsBytes(widget.bytes);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('SAVED TO DOCUMENTS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              backgroundColor: Color(0xFF1A1A1A),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ERROR: $e', style: const TextStyle(color: Colors.white)), 
            backgroundColor: Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _addToCloud() async {
    setState(() => _isAddingToCloud = true);
    try {
      final success = await BackupService().uploadSharedImage(
        widget.bytes, 
        'shared_${widget.share.id}.jpg'
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(success ? 'ADDED TO CLOUD' : 'FAILED TO ADD', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
            backgroundColor: success ? const Color(0xFF1A1A1A) : Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ERROR: $e', style: const TextStyle(color: Colors.white)), 
            backgroundColor: Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isAddingToCloud = false);
    }
  }

  Future<void> _deleteShare() async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.black,
      isScrollControlled: true,
      builder: (context) => _ConfirmDeleteSheet(
        onConfirm: () => Navigator.pop(context, true),
        onCancel: () => Navigator.pop(context, false),
      ),
    );

    if (confirm != true) return;

    setState(() => _isDeleting = true);
    try {
      final success = await ShareService().deleteReceivedShare(widget.share.id);
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('SHARE REMOVED', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
              backgroundColor: Color(0xFF1A1A1A),
              behavior: SnackBarBehavior.floating,
            ),
          );
          context.pop(true);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('REMOVE FAILED', style: TextStyle(color: Colors.white)),
              backgroundColor: Colors.red.shade900,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ERROR: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.red.shade900,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Main Image
          Positioned.fill(
            child: Hero(
              tag: 'share_${widget.share.id}',
              child: ExtendedImage.memory(
                widget.bytes,
                fit: BoxFit.contain,
                mode: ExtendedImageMode.gesture,
                initGestureConfigHandler: (state) {
                  return GestureConfig(
                    minScale: 0.9,
                    animationMinScale: 0.7,
                    maxScale: 6.0,
                    animationMaxScale: 7.0,
                    speed: 1.0,
                    inertialSpeed: 100.0,
                    initialScale: 1.0,
                    inPageView: false,
                    initialAlignment: InitialAlignment.center,
                  );
                },
              ),
            ),
          ),

          // Minimal Top Bar with visibility gradient
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.4),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () => context.pop(),
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.3),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close, color: Colors.white, size: 24),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Text(
                          widget.senderUsername.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white, 
                            fontSize: 10, 
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Modern Bottom Action Bar (Aligned with Asset Viewer)
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.only(bottom: 32, left: 24, right: 24),
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 15,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _ActionIcon(
                    icon: Icons.download_outlined,
                    label: 'DOWNLOAD',
                    isLoading: _isSaving,
                    onTap: _downloadImage,
                  ),
                  _ActionIcon(
                    icon: Icons.cloud_outlined,
                    label: 'CLOUD',
                    isLoading: _isAddingToCloud,
                    onTap: _addToCloud,
                  ),
                  _ActionIcon(
                    icon: Icons.delete_outline,
                    label: 'DELETE',
                    isLoading: _isDeleting,
                    onTap: _deleteShare,
                    isDestructive: true,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isLoading;
  final VoidCallback onTap;
  final bool isDestructive;

  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.isLoading,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(15),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLoading)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white24),
              )
            else
              Icon(
                icon, 
                color: isDestructive ? Colors.white.withOpacity(0.5) : Colors.white, 
                size: 22
              ),
            const SizedBox(height: 4),
            Text(
              label, 
              style: TextStyle(
                color: isDestructive ? Colors.white24 : Colors.white70, 
                fontSize: 8,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              )
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmDeleteSheet extends StatelessWidget {
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _ConfirmDeleteSheet({
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'DISMISS SHARE?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 3.0,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'THIS ACTION WILL REMOVE THE PHOTO FROM YOUR LIST. IT CANNOT BE UNDONE WITHOUT A NEW LINK.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              height: 2.0,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 60),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: onCancel,
                child: const Text(
                  'CANCEL',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onConfirm,
                child: const Text(
                  'CONFIRM',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
