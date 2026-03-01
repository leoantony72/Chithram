import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:image/image.dart' as img;
import 'package:uuid/uuid.dart';

class ImageEditPage extends StatefulWidget {
  final AssetEntity asset;
  const ImageEditPage({super.key, required this.asset});

  @override
  State<ImageEditPage> createState() => _ImageEditPageState();
}

class _ImageEditPageState extends State<ImageEditPage> {
  final GlobalKey<ExtendedImageEditorState> _editorKey = GlobalKey<ExtendedImageEditorState>();
  bool _isSaving = false;
  int _rotationCount = 0;
  bool _isFlipped = false;
  File? _imageFile;
  bool _isLoadingFile = true;

  @override
  void initState() {
    super.initState();
    _loadFile();
  }

  Future<void> _loadFile() async {
    final file = await widget.asset.file;
    if (mounted) {
      setState(() {
        _imageFile = file;
        _isLoadingFile = false;
      });
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
      if (rawData == null || cropRect == null) return;

      // Perform crop and rotate in background/compute if it's too heavy
      // For now, using the image package
      final img.Image? originalImage = img.decodeImage(rawData);
      if (originalImage == null) return;

      // Apply transformations from editor state
      img.Image transformed = originalImage;
      
      // Handle rotation manually tracked
      if (_rotationCount != 0) {
        transformed = img.copyRotate(transformed, angle: (_rotationCount * 90));
      }

      // Handle flip
      if (_isFlipped) {
        transformed = img.flip(transformed, direction: img.FlipDirection.horizontal);
      }

      // Handle cropping
      transformed = img.copyCrop(
        transformed,
        x: cropRect.left.toInt(),
        y: cropRect.top.toInt(),
        width: cropRect.width.toInt(),
        height: cropRect.height.toInt(),
      );

      final Uint8List editedBytes = Uint8List.fromList(img.encodeJpg(transformed));

      if (overwrite) {
        // Workaround for "Permission Denied" on Android/iOS (Scoped Storage)
        // 1. Save edited image as a new asset
        final AssetEntity? newAsset = await PhotoManager.editor.saveImage(
          editedBytes,
          title: widget.asset.title ?? 'edited_${const Uuid().v4()}',
          filename: 'edited_${const Uuid().v4()}.jpg',
        );
        
        if (newAsset != null) {
          // 2. Delete the original asset using IDs (requires user confirmation on some platforms)
          await PhotoManager.editor.deleteWithIds([widget.asset.id]);
        } else {
          throw Exception("Failed to save edited image.");
        }
      } else {
        // Save as copy
        final AssetEntity? newAsset = await PhotoManager.editor.saveImage(
          editedBytes,
          title: 'edited_${widget.asset.title ?? "image"}',
          filename: 'edited_${const Uuid().v4()}.jpg',
        );
        
        if (newAsset == null) {
           throw Exception("Failed to save edited copy.");
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
    if (_imageFile == null) {
      return const Center(child: Text("Error loading file", style: TextStyle(color: Colors.white)));
    }

    return ExtendedImage.file(
      _imageFile!,
      fit: BoxFit.contain,
      mode: ExtendedImageMode.editor,
      extendedImageEditorKey: _editorKey,
      cacheRawData: true,
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
