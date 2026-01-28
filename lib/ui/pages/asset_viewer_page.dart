import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:extended_image/extended_image.dart';
import '../../providers/photo_provider.dart';
import '../widgets/video_viewer.dart';
import '../widgets/photo_viewer.dart';

class AssetViewerPage extends StatefulWidget {
  final AssetEntity asset;

  const AssetViewerPage({super.key, required this.asset});

  @override
  State<AssetViewerPage> createState() => _AssetViewerPageState();
}

class _AssetViewerPageState extends State<AssetViewerPage> {
  late ExtendedPageController _pageController;
  late int _currentIndex;
  // We keep a local reference to the list to avoid provider shifting issues during view
  late List<AssetEntity> _assets; 
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
    // Logic deferred to didChangeDependencies to access Provider safely
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInit) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      _assets = provider.allAssets;
      // Find initial index
      final index = _assets.indexWhere((e) => e.id == widget.asset.id);
      _currentIndex = index != -1 ? index : 0;
      
      _pageController = ExtendedPageController(initialPage: _currentIndex);
      _isInit = true;
      
      // Precache neighbors immediately
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _precacheImages(_currentIndex);
      });
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    setState(() {
      _currentIndex = index;
    });
    _precacheImages(index);
  }

  void _precacheImages(int index) {
    // Proactively decode the Previous and Next images so they are ready
    // BEFORE the user swipes. 
    final indexesToCache = [index - 1, index + 1];
    
    for (final i in indexesToCache) {
       if (i >= 0 && i < _assets.length) {
          final asset = _assets[i];
          if (asset.type == AssetType.image) {
             _precacheSingleAsset(asset);
          }
       }
    }
  }

  Future<void> _precacheSingleAsset(AssetEntity asset) async {
      // Logic MUST match PhotoViewer's request exacty to hit the cache.
      final mediaQuery = MediaQuery.of(context);
      final pixelRatio = mediaQuery.devicePixelRatio;
      final targetWidth = (mediaQuery.size.width * pixelRatio).toInt();
      final targetHeight = (mediaQuery.size.height * pixelRatio).toInt();
      
      final provider = AssetEntityImageProvider(
        asset,
        isOriginal: false,
        thumbnailSize: ThumbnailSize(targetWidth, targetHeight),
        thumbnailFormat: ThumbnailFormat.jpeg,
      );
      
      // precacheImage puts it directly into the Flutter ImageCache as a decoded image.
      // This is superior to just fetching bytes because it saves the decoding step during the swipe.
      await precacheImage(provider, context);
  }


  @override
  Widget build(BuildContext context) {
    if (!_isInit) return const Scaffold(backgroundColor: Colors.black);
    
    // Safety check if list is empty
    if (_assets.isEmpty) {
        return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.transparent),
            body: const Center(child: Text("No photos", style: TextStyle(color: Colors.white)))
        );
    }
    
    final currentAsset = _assets[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent, // Make it completely transparent
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
           _formatDateTime(currentAsset.createDateTime),
           style: const TextStyle(
             color: Colors.white70, 
             fontSize: 14,
             shadows: [Shadow(color: Colors.black, blurRadius: 4)]
           ),
        ),
      ),
      body: ExtendedImageGesturePageView.builder(
        controller: _pageController,
        itemCount: _assets.length,
        // allowImplicitScrolling: true, // ExtendedImageGesturePageView handles this differently
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final asset = _assets[index];
          return _buildItem(asset, index);
        },
      ),
    );
  }
  
  Widget _buildItem(AssetEntity asset, int index) {
    // Only allow video to load/play if it is the current page.
    // This prevents multiple video players (heavy native resources) from being active simultaneously,
    // which fixes the crash/OOM issue.
    final isActive = index == _currentIndex;

    if (asset.type == AssetType.video) {
      return VideoViewer(
        asset: asset,
        isActive: isActive,
      );
    }
    
    // Use the optimized PhotoViewer which caches the file and maintains state
    return PhotoViewer(
      asset: asset,
      isActive: isActive,
    );
  }

  String _formatDateTime(DateTime date) {
    return DateFormat('d MMM yyyy, HH:mm').format(date);
  }
}
