import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../models/photo_group.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/draggable_scroll_icon.dart';

class AlbumDetailsPage extends StatefulWidget {
  final AssetPathEntity album;

  const AlbumDetailsPage({
    super.key,
    required this.album,
  });

  @override
  State<AlbumDetailsPage> createState() => _AlbumDetailsPageState();
}

class _AlbumDetailsPageState extends State<AlbumDetailsPage> {
  List<PhotoGroup> _groupedAssets = [];
  bool _isLoading = true;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _isFastScrolling = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    _loadAlbumAssets();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _isFastScrolling.dispose();
    super.dispose();
  }

  Future<void> _loadAlbumAssets() async {
    // Progressive Loading:
    // 1. Fetch first 500 items to show UI immediately
    // 2. Fetch the rest in background

    final int totalCount = await widget.album.assetCountAsync;
    final int firstBatch = 500;
    
    // Fetch initial batch
    final initialAssets = await widget.album.getAssetListRange(start: 0, end: firstBatch);
    _updateGroups(initialAssets);
    
    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }

    // Fetch remaining if any
    if (totalCount > firstBatch) {
      // Small delay to allow initial frame to render smooth
      await Future.delayed(const Duration(milliseconds: 100));
      
      final remainingAssets = await widget.album.getAssetListRange(start: firstBatch, end: totalCount);
      if (mounted) {
         // Combine and re-group. 
         // Note: merging lists and regrouping 5k-10k items is fast (sync).
         final allAssets = [...initialAssets, ...remainingAssets];
         _updateGroups(allAssets);
         setState(() {});
      }
    }
  }

  void _updateGroups(List<AssetEntity> assets) {
    // Group by Day
    final Map<DateTime, List<AssetEntity>> dayGroups = groupBy(assets, (AssetEntity e) {
      return DateTime(e.createDateTime.year, e.createDateTime.month, e.createDateTime.day);
    });

    final List<PhotoGroup> grouped = dayGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    
    // Sort descending
    grouped.sort((a, b) => b.date.compareTo(a.date));
    
    _groupedAssets = grouped;
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    if (date.year == now.year && date.month == now.month && date.day == now.day) {
      return 'Today';
    }
    if (date.year == now.year && date.month == now.month && date.day == now.day - 1) {
      return 'Yesterday';
    }
    return DateFormat('EEE, d MMM').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.album.name),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedAssets.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.photo_album_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No photos in this album.', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                )
              : DraggableScrollIcon(
                  controller: _scrollController,
                  backgroundColor: Colors.grey[900]!.withOpacity(0.8),
                  onDragStart: () => _isFastScrolling.value = true,
                  onDragEnd: () => _isFastScrolling.value = false,
                  child: CustomScrollView(
                    controller: _scrollController,
                    physics: const BouncingScrollPhysics(),
                    slivers: [
                      for (var group in _groupedAssets) ...[
                        SliverPersistentHeader(
                          pinned: false,
                          delegate: SectionHeaderDelegate(
                            title: _formatDate(group.date),
                          ),
                        ),
                        SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3, 
                            crossAxisSpacing: 2,
                            mainAxisSpacing: 2,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final AssetEntity entity = group.assets[index];
                              return ThumbnailWidget(
                                entity: entity,
                                isFastScrolling: _isFastScrolling, 
                                heroTagPrefix: 'album_details_${widget.album.id}',
                              );
                            },
                            childCount: group.assets.length,
                          ),
                        ),
                      ]
                    ],
                  ),
                ),
    );
  }
}
