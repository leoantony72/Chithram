import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../providers/photo_provider.dart';
import '../../models/gallery_item.dart';
import '../../models/photo_group.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/draggable_scroll_icon.dart';

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
          final int crossAxisCount = isMobile ? 3 : 6;

          return CustomScrollView(
            controller: _scrollController,
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
          );
        }
      )
    );
  }
}
