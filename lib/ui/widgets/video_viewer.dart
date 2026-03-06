import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:video_player/video_player.dart';

class VideoViewer extends StatefulWidget {
  final AssetEntity asset;
  final bool assetIsActive;
  final bool showUI;

  const VideoViewer({
    super.key, 
    required this.asset,
    required this.assetIsActive,
    required this.showUI,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _videoController;
  Uint8List? _thumbnailBytes;
  bool _isPlayerInitialized = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
    if (widget.assetIsActive) {
      _initVideo();
    }
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.assetIsActive != widget.assetIsActive) {
      if (widget.assetIsActive) {
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
    await _videoController?.dispose();
    _videoController = null;
    if (mounted) {
      setState(() {
        _isPlayerInitialized = false;
      });
    }
  }

  Future<void> _loadThumbnail() async {
    final bytes = await widget.asset.thumbnailDataWithSize(const ThumbnailSize(1200, 1200));
    if (mounted) {
      setState(() {
        _thumbnailBytes = bytes;
      });
    }
  }

  Future<void> _initVideo() async {
    if (_videoController != null) return; 

    try {
      final file = await widget.asset.file;
      if (file == null) return;
      
      if (!mounted) return;

      _videoController = VideoPlayerController.file(file);
      await _videoController!.initialize();
      
      if (!mounted) {
         await _videoController?.dispose();
         return;
      }

      await _videoController!.setLooping(true);
      await _videoController!.play();

      _videoController!.addListener(() {
        if (mounted) {
          setState(() {}); // Rebuild for progress bar
        }
      });

      setState(() {
        _isPlayerInitialized = true;
      });
    } catch (e) {
      debugPrint("Error initializing video: $e");
      _disposeVideo();
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return duration.inHours > 0 
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.assetIsActive || !_isPlayerInitialized || _videoController == null) {
      if (_thumbnailBytes != null) {
         return Stack(
           alignment: Alignment.center,
           children: [
             Image.memory(
               _thumbnailBytes!, 
               fit: BoxFit.contain,
               width: double.infinity,
               height: double.infinity,
               errorBuilder: (context, error, stackTrace) => const Center(child: Icon(Icons.broken_image, color: Colors.white24, size: 64)),
             ),
             if (widget.assetIsActive)
               const CircularProgressIndicator(color: Colors.white),
             if (!widget.assetIsActive)
               const Icon(Icons.play_circle_outline, size: 64, color: Colors.white70),
           ],
         );
      }
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    final duration = _videoController!.value.duration;
    final position = _videoController!.value.position;

    return Stack(
      children: [
        // Video Layer
        Center(
          child: AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          ),
        ),
        
        // Center Play/Pause Overlay
        if (widget.showUI)
          Center(
            child: GestureDetector(
              onTap: () {
                _videoController!.value.isPlaying 
                    ? _videoController!.pause() 
                    : _videoController!.play();
                setState(() {});
              },
              child: AnimatedOpacity(
                opacity: _videoController!.value.isPlaying ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(16),
                  child: const Icon(
                    Icons.play_arrow,
                    size: 48,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        
        // Bottom Controls Layer
        if (widget.showUI)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.only(left: 20, right: 20, bottom: 100, top: 40),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.black54, Colors.transparent],
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                   Row(
                     children: [
                        Text(
                          _formatDuration(position),
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                        Expanded(
                          child: VideoProgressIndicator(
                             _videoController!,
                             allowScrubbing: true,
                             padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                             colors: const VideoProgressColors(
                                playedColor: Colors.red,
                                bufferedColor: Colors.white30,
                                backgroundColor: Colors.white12,
                             ),
                          )
                        ),
                        Text(
                          _formatDuration(duration),
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                     ],
                   )
                ],
              ),
            ),
          ),
      ],
    );
  }
}
