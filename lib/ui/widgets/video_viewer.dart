import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class VideoViewer extends StatefulWidget {
  final AssetEntity asset;
  final bool isActive;

  const VideoViewer({
    super.key, 
    required this.asset,
    required this.isActive,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  Uint8List? _thumbnailBytes;
  bool _isPlayerInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
    if (widget.isActive) {
      _initVideo();
    }
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        _initVideo();
      } else {
        _disposeVideo();
      }
    }
  }

  @override
  void dispose() {
    _disposeVideo();
    super.dispose();
  }

  Future<void> _disposeVideo() async {
    _chewieController?.dispose();
    _chewieController = null;
    await _videoController?.dispose();
    _videoController = null;
    if (mounted) {
      setState(() {
        _isPlayerInitialized = false;
      });
    }
  }

  Future<void> _loadThumbnail() async {
    final bytes = await widget.asset.thumbnailData;
    if (mounted) {
      setState(() {
        _thumbnailBytes = bytes;
      });
    }
  }

  Future<void> _initVideo() async {
    if (_videoController != null) return; // Already initializing or initialized

    try {
      final file = await widget.asset.file;
      if (file == null) return;
      
      if (!mounted) return;

      // Note: VideoPlayerController.file actually streams the video from the disk.
      // It does NOT load the entire file into memory which is good for avoiding OOM.
      // For very small files, the OS file cache effectively keeps them in memory.
      // 
      // By disposing the controller when !isActive, we ensure packets are discarded 
      // from memory as requested.
      _videoController = VideoPlayerController.file(file);
      
      await _videoController!.initialize();
      
      if (!mounted) {
         await _videoController?.dispose();
         return;
      }

      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: true,
        aspectRatio: _videoController!.value.aspectRatio,
        placeholder: _thumbnailBytes != null 
            ? Image.memory(_thumbnailBytes!, fit: BoxFit.contain)
            : const Center(child: CircularProgressIndicator()),
        errorBuilder: (context, errorMessage) {
          return Center(child: Text(errorMessage, style: const TextStyle(color: Colors.white)));
        },
      );

      setState(() {
        _isPlayerInitialized = true;
      });
    } catch (e) {
      debugPrint("Error initializing video: $e");
      // Clean up if failure
      _disposeVideo();
    }
  }

  @override
  Widget build(BuildContext context) {
    // If not active or not initialized, show thumbnail/loader
    if (!widget.isActive || !_isPlayerInitialized || _chewieController == null) {
      if (_thumbnailBytes != null) {
         return Stack(
           alignment: Alignment.center,
           children: [
             Image.memory(
               _thumbnailBytes!, 
               fit: BoxFit.contain,
               width: double.infinity,
               height: double.infinity,
             ),
             // Show a play icon or loader if it's supposed to be active but loading
             if (widget.isActive)
               const CircularProgressIndicator(color: Colors.white),
             if (!widget.isActive)
               const Icon(Icons.play_circle_outline, size: 64, color: Colors.white70),
           ],
         );
      }
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    return SafeArea(
      child: Chewie(controller: _chewieController!),
    );
  }
}
