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
import '../../models/gallery_item.dart';
import '../widgets/video_viewer.dart';
import '../widgets/photo_viewer.dart';
import '../widgets/remote_photo_viewer.dart';

class AssetViewerPage extends StatefulWidget {
  final GalleryItem item; // Changed from AssetEntity

  const AssetViewerPage({super.key, required this.item});

  @override
  State<AssetViewerPage> createState() => _AssetViewerPageState();
}

class _AssetViewerPageState extends State<AssetViewerPage> {
  late ExtendedPageController _pageController;
  late int _currentIndex;
  late List<GalleryItem> _items; 
  bool _isInit = false;

  @override
  void initState() {
    super.initState();
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInit) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      _items = provider.allItems; // Use unified list
      
      // Find initial index
      final index = _items.indexWhere((e) => e.id == widget.item.id);
      _currentIndex = index != -1 ? index : 0;
      
      _pageController = ExtendedPageController(initialPage: _currentIndex);
      _isInit = true;
      
      // Precache neighbors
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
    // Proactively decode neighbor local images
    final indexesToCache = [index - 1, index + 1];
    
    for (final i in indexesToCache) {
       if (i >= 0 && i < _items.length) {
          final item = _items[i];
          if (item.type == GalleryItemType.local && item.local!.type == AssetType.image) {
             _precacheSingleAsset(item.local!);
          }
          // Note: Remote image precaching is complex due to encryption, skipped for now
       }
    }
  }

  Future<void> _precacheSingleAsset(AssetEntity asset) async {
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
      
      await precacheImage(provider, context);
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) return const Scaffold(backgroundColor: Colors.black);
    
    if (_items.isEmpty) {
        return Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(backgroundColor: Colors.transparent),
            body: const Center(child: Text("No photos", style: TextStyle(color: Colors.white)))
        );
    }
    
    final currentItem = _items[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Text(
           _formatDateTime(currentItem.date),
           style: const TextStyle(
             color: Colors.white70, 
             fontSize: 14,
             shadows: [Shadow(color: Colors.black, blurRadius: 4)]
           ),
        ),
      ),
      body: ExtendedImageGesturePageView.builder(
        controller: _pageController,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final item = _items[index];
          return _buildItem(item, index);
        },
      ),
    );
  }
  
  Widget _buildItem(GalleryItem item, int index) {
    final isActive = index == _currentIndex;

    if (item.type == GalleryItemType.local) {
       final asset = item.local!;
       if (asset.type == AssetType.video) {
         return VideoViewer(asset: asset, isActive: isActive);
       }
       return PhotoViewer(asset: asset, isActive: isActive);
    } else {
       // Remote
       final remote = item.remote!;
       // TODO: RemoteVideoViewer implementation if desired
       return RemotePhotoViewer(remote: remote, isActive: isActive);
    }
  }

  String _formatDateTime(DateTime date) {
    return DateFormat('d MMM yyyy, HH:mm').format(date);
  }
}
