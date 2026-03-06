import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../providers/photo_provider.dart';
import '../../providers/selection_provider.dart';
import '../../models/gallery_item.dart';
import '../../models/photo_group.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/draggable_scroll_icon.dart';
import '../widgets/album_picker_dialog.dart';

class PlaceGridPage extends StatefulWidget {
  final String city;
  
  const PlaceGridPage({super.key, required this.city});

  @override
  State<PlaceGridPage> createState() => _PlaceGridPageState();
}

class _PlaceGridPageState extends State<PlaceGridPage> {
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _isFastScrolling = ValueNotifier(false);

  @override
  void dispose() {
    _scrollController.dispose();
    _isFastScrolling.dispose();
    super.dispose();
  }

  String _formatDate(DateTime date) {
    return DateFormat('MMM d, yyyy').format(date);
  }

  Widget _buildActionIcon(IconData icon, String label, VoidCallback onTap, {Color color = Colors.white}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        splashColor: color.withOpacity(0.2),
        highlightColor: color.withOpacity(0.1),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(color: color.withOpacity(0.8), fontSize: 11, fontWeight: FontWeight.w600),
              )
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<PhotoProvider>(
        builder: (context, provider, child) {
          final photos = provider.placesVisited[widget.city] ?? [];
          
          if (photos.isEmpty) {
             return Scaffold(
                backgroundColor: Colors.black,
                appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.city)),
                body: const Center(child: Text('No photos found.', style: TextStyle(color: Colors.white)))
             );
          }

          // Group the photos dynamically by day for this specific place
          final Map<DateTime, List<GalleryItem>> dayGroups = groupBy(photos, (GalleryItem e) {
            return DateTime(e.date.year, e.date.month, e.date.day);
          });

          List<PhotoGroup> groups = dayGroups.entries.map((entry) {
            return PhotoGroup(date: entry.key, items: entry.value);
          }).toList();
          groups.sort((a, b) => b.date.compareTo(a.date));

          final double screenWidth = MediaQuery.of(context).size.width;
          final bool isMobile = screenWidth < 600;
          final int crossAxisCount = isMobile ? 4 : 7;

          return Stack(
            children: [
              DraggableScrollIcon(
                controller: _scrollController,
                backgroundColor: Colors.grey[900]!.withOpacity(0.8),
                onDragStart: () => _isFastScrolling.value = true,
                onDragEnd: () => _isFastScrolling.value = false,
                groups: groups,
                crossAxisCount: crossAxisCount,
                labelFormatter: (date) => _formatDate(date),
                child: CustomScrollView(
                  controller: _scrollController,
                  cacheExtent: 2000,
                  physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                  slivers: [
                    SliverAppBar(
                      backgroundColor: Colors.black,
                      pinned: true,
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => context.pop(),
                      ),
                      title: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.city, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          Text('${photos.length} memories', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                    for (var group in groups) ...[
                      SliverPersistentHeader(
                        pinned: false,
                        delegate: SectionHeaderDelegate(
                          title: _formatDate(group.date),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                        sliver: SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 4,
                            mainAxisSpacing: 4,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final GalleryItem item = group.items[index];
                              return ThumbnailWidget(
                                item: item,
                                isFastScrolling: _isFastScrolling,
                                heroTagPrefix: 'place_grid_${widget.city}',
                                onTap: () {
                                  context.push('/viewer', extra: {
                                    'item': item,
                                    'items': photos,
                                  });
                                },
                              );
                            },
                            childCount: group.items.length,
                          ),
                        ),
                      ),
                    ],
                    const SliverToBoxAdapter(
                       child: SizedBox(height: 100),
                    )
                  ],
                ),
              ),
              
              // Selection Action Bar
              Consumer<SelectionProvider>(
                builder: (context, selection, child) {
                  if (!selection.isSelectionMode || selection.selectedItems.isEmpty) return const SizedBox.shrink();

                  return Positioned(
                    bottom: 24,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(40),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(40),
                              border: Border.all(color: Colors.white.withOpacity(0.15)),
                              boxShadow: const [
                                BoxShadow(color: Colors.black45, blurRadius: 40, spreadRadius: 0, offset: Offset(0, 10))
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildActionIcon(Icons.auto_awesome_mosaic_rounded, 'Album', () async {
                                   final sp = Provider.of<SelectionProvider>(context, listen: false);
                                   final pp = Provider.of<PhotoProvider>(context, listen: false);
                                   final items = List<GalleryItem>.from(sp.selectedItems);
                                   sp.clearSelection();
                                   
                                   final localAlbums = pp.paths;
                                   final Set<String> cloudAlbumNames = {};
                                   for (var remote in pp.allItems.where((e) => e.type == GalleryItemType.remote)) {
                                      if (remote.remote!.album.isNotEmpty) {
                                         cloudAlbumNames.add(remote.remote!.album);
                                      }
                                   }

                                   final result = await showDialog<AlbumSelectionResult>(
                                      context: context,
                                      builder: (ctx) => AlbumPickerDialog(
                                         localAlbums: localAlbums,
                                         existingCloudAlbums: cloudAlbumNames.toList()..sort(),
                                      )
                                   );
                                   if (result != null) {
                                      final String? error = await pp.addSelectedToAlbum(items, result.localAlbum, result.cloudAlbumName);
                                      if (error != null && mounted) {
                                         ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                            content: Text(error, style: const TextStyle(color: Colors.white)),
                                            backgroundColor: Colors.redAccent,
                                            duration: const Duration(seconds: 4),
                                         ));
                                      }
                                   }
                                }),
                                const SizedBox(width: 8),
                                _buildActionIcon(Icons.delete_outline_rounded, 'Delete', () async {
                                   final sp = Provider.of<SelectionProvider>(context, listen: false);
                                   final pp = Provider.of<PhotoProvider>(context, listen: false);
                                   final items = List<GalleryItem>.from(sp.selectedItems);
                                   
                                   sp.clearSelection();
                                   await pp.deleteSelectedPhotos(context, items);
                                }, color: Colors.redAccent),
                                const SizedBox(width: 8),
                                _buildActionIcon(Icons.close_rounded, 'Clear', () {
                                   Provider.of<SelectionProvider>(context, listen: false).clearSelection();
                                }),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        }
      )
    );
  }
}
