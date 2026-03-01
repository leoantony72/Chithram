import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:extended_image/extended_image.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';
import '../../services/thumbnail_cache.dart';
import '../../providers/photo_provider.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../../services/backup_service.dart';

class ImageEditPage extends StatefulWidget {
  final AssetEntity? asset;
  final File? file;
  final String? remoteImageId;
  const ImageEditPage({super.key, this.asset, this.file, this.remoteImageId});

  @override
  State<ImageEditPage> createState() => _ImageEditPageState();
}

class _ImageEditPageState extends State<ImageEditPage> {
  final GlobalKey<ExtendedImageEditorState> _editorKey = GlobalKey<ExtendedImageEditorState>();
  bool _isSaving = false;
  int _rotationCount = 0;
  bool _isFlipped = false;
  Uint8List? _imageBytes;
  File? _imageFile; // Keep for path reference
  bool _isLoadingFile = true;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    File? file = widget.file;

    if (file == null && widget.asset != null) {
      if (Platform.isWindows) {
        file = await ThumbnailCache().getConvertedHighResFile(widget.asset!);
      }
      file ??= await widget.asset!.file;
    }

    if (file != null && await file.exists()) {
      final bytes = await file.readAsBytes();
      if (mounted) {
        setState(() {
          _imageFile = file;
          _imageBytes = bytes;
          _isLoadingFile = false;
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _isLoadingFile = false;
        });
      }
    }
  }

  void _rotate(bool clockwise) {
    if (clockwise) {
      _editorKey.currentState?.rotate();
      _rotationCount = (_rotationCount + 1) % 4;
    } else {
      // If rotate() doesn't support 'clockwise' parameter, use 3 CW rotations for CCW
      _editorKey.currentState?.rotate();
      _editorKey.currentState?.rotate();
      _editorKey.currentState?.rotate();
      _rotationCount = (_rotationCount - 1) % 4;
    }
    setState(() {});
  }

  Future<void> _save(bool overwrite) async {
    setState(() => _isSaving = true);
    try {
      final state = _editorKey.currentState;
      if (state == null) return;

      final Rect? cropRect = state.getCropRect();
      final Uint8List? rawData = state.rawImageData;
      if (rawData == null || cropRect == null) {
        throw Exception("Image data not ready. Please wait a moment.");
      }

      // offload heavy processing to isolate
      final Uint8List editedBytes = await compute(_processImage, {
        'rawData': rawData,
        'cropRect': {
          'left': cropRect.left,
          'top': cropRect.top,
          'width': cropRect.width,
          'height': cropRect.height,
        },
        'rotationCount': _rotationCount,
        'isFlipped': _isFlipped,
      });

      if (editedBytes.isEmpty) throw Exception("Failed to process image.");

      if (Platform.isWindows) {
        // --- Windows Specific Saving ---
        File? sourceFile = _imageFile;
        // If we have an asset, try to get its original file for overwriting
        if (overwrite && widget.asset != null) {
           sourceFile = await widget.asset!.file;
        }

        if (sourceFile == null) throw Exception("Could not locate source file for saving.");

        String targetPath;
        bool isTemp = sourceFile.path.contains('Temp') || sourceFile.path.contains('edit_');

        if (overwrite && !isTemp) {
          targetPath = sourceFile.path;
          await sourceFile.writeAsBytes(editedBytes);
        } else {
          // Saving a copy OR saving a temporary file (remote-originated)
          Directory? baseDir;
          if (isTemp || Platform.isWindows) {
             // For Windows, default to a visible "Ninta" folder in Pictures if possible
             final userProfile = Platform.environment['USERPROFILE'];
             if (userProfile != null) {
               final pictures = Directory(p.join(userProfile, 'Pictures', 'Ninta'));
               if (!await pictures.exists()) await pictures.create(recursive: true);
               baseDir = pictures;
             }
          }
          
          baseDir ??= sourceFile.parent;
          baseDir ??= await getDownloadsDirectory();

          final originalName = isTemp 
              ? 'Ninta_Edit' 
              : p.basenameWithoutExtension(sourceFile.path);
          final ext = p.extension(sourceFile.path).isEmpty ? '.jpg' : p.extension(sourceFile.path);
          targetPath = p.join(baseDir!.path, '${originalName}_edited_${const Uuid().v4().substring(0, 8)}$ext');
          
          await File(targetPath).writeAsBytes(editedBytes);
        }

        // --- Cloud Sync ---
        try {
          final String? rid = widget.remoteImageId ?? (widget.asset?.id.startsWith('cloud_') == true ? widget.asset!.id.substring(6) : null);
          if (rid != null) {
            await BackupService().uploadEditedImage(
              bytes: editedBytes,
              originalImageId: rid,
              isNewCopy: !overwrite,
            );
          }
        } catch (e) {
          debugPrint("Cloud Sync Error: $e");
          // Non-fatal, image is still saved locally
        }
        
        // Invalidate thumbnail cache if overwriting
        if (overwrite && widget.asset != null) {
          await ThumbnailCache().invalidate(widget.asset!.id);
        }
        
        // Refresh provider to pick up changes
        final provider = Provider.of<PhotoProvider>(context, listen: false);
        await provider.fetchAssets(force: true);
      } else {
        // --- Mobile Specific Saving (PhotoManager) ---
        AssetEntity? savedAsset;
        if (overwrite && widget.asset != null) {
          savedAsset = await PhotoManager.editor.saveImage(
            editedBytes,
            title: widget.asset!.title ?? 'edited_${const Uuid().v4()}',
            filename: 'edited_${const Uuid().v4()}.jpg',
          );
          if (savedAsset != null) {
            await PhotoManager.editor.deleteWithIds([widget.asset!.id]);
          }
        } else {
          final title = widget.asset?.title ?? 'edited_${const Uuid().v4().substring(0,8)}';
          savedAsset = await PhotoManager.editor.saveImage(
            editedBytes,
            title: 'edited_$title',
            filename: 'edited_${const Uuid().v4()}.jpg',
          );
        }

        if (savedAsset == null) {
           throw Exception("Failed to save edited image.");
        }

        // --- Cloud Sync (Mobile) ---
        try {
          final String? rid = widget.remoteImageId ?? (widget.asset?.id.startsWith('cloud_') == true ? widget.asset!.id.substring(6) : null);
          if (rid != null) {
            await BackupService().uploadEditedImage(
              bytes: editedBytes,
              originalImageId: rid,
              isNewCopy: !overwrite,
            );
          }
        } catch (e) {
          debugPrint("Cloud Sync Error (Mobile): $e");
        }

        // Invalidate thumbnail cache if overwriting
        if (overwrite && widget.asset != null) {
          await ThumbnailCache().invalidate(widget.asset!.id);
        }

        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(
               content: Text("Image saved to gallery"),
               behavior: SnackBarBehavior.floating,
               backgroundColor: Color(0xFF1A1A1A),
             ),
           );
        }
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      debugPrint("Error saving edited image: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error saving image: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  static Uint8List _processImage(Map<String, dynamic> params) {
    try {
      final Uint8List rawData = params['rawData'];
      final Map<String, dynamic> cropParams = params['cropRect'];
      final int rotationCount = params['rotationCount'];
      final bool isFlipped = params['isFlipped'];

      img.Image? image = img.decodeImage(rawData);
      if (image == null) return Uint8List(0);

      img.Image transformed = image;
      if (rotationCount != 0) {
        transformed = img.copyRotate(transformed, angle: rotationCount * 90);
      }

      if (isFlipped) {
        transformed = img.flip(transformed, direction: img.FlipDirection.horizontal);
      }

      transformed = img.copyCrop(
        transformed,
        x: cropParams['left']!.toInt(),
        y: cropParams['top']!.toInt(),
        width: cropParams['width']!.toInt(),
        height: cropParams['height']!.toInt(),
      );

      return Uint8List.fromList(img.encodeJpg(transformed, quality: 90));
    } catch (e) {
      debugPrint("Isolate process error: $e");
      return Uint8List(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text("Edit", style: TextStyle(color: Colors.white)),
        actions: [
          if (_isSaving)
            const Center(child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ))
          else
            TextButton(
              onPressed: () => _showSaveOptions(),
              child: const Text("SAVE", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Container(
              alignment: Alignment.center,
              color: Colors.black,
              child: _buildEditorWrap(),
            ),
          ),
          _buildToolbar(),
        ],
      ),
    );
  }

  Widget _buildEditorWrap() {
    if (_isLoadingFile) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_imageBytes == null) {
      return const Center(child: Text("Error loading file", style: TextStyle(color: Colors.white)));
    }

    return ExtendedImage.memory(
      _imageBytes!,
      fit: BoxFit.contain,
      mode: ExtendedImageMode.editor,
      extendedImageEditorKey: _editorKey,
      initEditorConfigHandler: (state) {
        return EditorConfig(
          maxScale: 8.0,
          cropRectPadding: const EdgeInsets.all(20.0),
          hitTestSize: 20.0,
        );
      },
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
      color: Colors.black,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _toolButton(Icons.rotate_left, "Rotate L", () => _rotate(false)),
          _toolButton(Icons.rotate_right, "Rotate R", () => _rotate(true)),
          _toolButton(Icons.flip, "Flip", () {
            _editorKey.currentState?.flip();
            setState(() => _isFlipped = !_isFlipped);
          }),
          _toolButton(Icons.refresh, "Reset", () {
            _editorKey.currentState?.reset();
            setState(() {
              _rotationCount = 0;
              _isFlipped = false;
            });
          }),
        ],
      ),
    );
  }

  Widget _toolButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 24),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
        ],
      ),
    );
  }

  void _showSaveOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 20),
              const Text("Save Changes", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ListTile(
                leading: const Icon(Icons.copy, color: Colors.white70),
                title: const Text("Save as Copy", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _save(false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.save, color: Colors.white70),
                title: const Text("Overwrite Original", style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(context);
                  _save(true);
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }
}
