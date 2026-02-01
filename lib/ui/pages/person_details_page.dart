import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../providers/photo_provider.dart';
import '../../models/photo_group.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/draggable_scroll_icon.dart';

class PersonDetailsPage extends StatefulWidget {
  final String personName;
  final int personId; // Use this to seed the mock data filter

  const PersonDetailsPage({
    super.key,
    required this.personName,
    required this.personId,
  });

  @override
  State<PersonDetailsPage> createState() => _PersonDetailsPageState();
}

class _PersonDetailsPageState extends State<PersonDetailsPage> {
  List<PhotoGroup> _groupedAssets = [];
  bool _isLoading = true;
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<bool> _isFastScrolling = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
    // Post-frame callback to safely access provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPersonAssets();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _isFastScrolling.dispose();
    super.dispose();
  }

  Future<void> _loadPersonAssets() async {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    
    // If assets definitely aren't loaded, wait or trigger load?
    // Assuming Home page already triggered load.
    if (provider.allAssets.isEmpty && !provider.isLoading) {
       await provider.fetchAssets();
    }

    final allAssets = provider.allAssets;
    
    // MOCK FILTER: Select a subset of photos based on personId to simulate "Faces"
    // We'll just pick assets where (index + personId) % 4 == 0, for ~25% of photos.
    final personAssets = allAssets.whereIndexed((index, element) {
      return (index + widget.personId) % 4 == 0;
    }).toList();

    // Group by Day (similar to Home Page logic)
    final Map<DateTime, List<AssetEntity>> dayGroups = groupBy(personAssets, (AssetEntity e) {
      return DateTime(e.createDateTime.year, e.createDateTime.month, e.createDateTime.day);
    });

    final List<PhotoGroup> grouped = dayGroups.entries.map((entry) {
      return PhotoGroup(date: entry.key, assets: entry.value);
    }).toList();
    
    // Sort descending
    grouped.sort((a, b) => b.date.compareTo(a.date));

    // Update State
    if (mounted) {
      setState(() {
        _groupedAssets = grouped;
        _isLoading = false;
      });
    }
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
      appBar: AppBar(
        title: Text(widget.personName),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedAssets.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.image_not_supported, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No photos found for this person.', style: TextStyle(color: Colors.grey)),
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
                          pinned: false, // Group headers scroll away like generic gallery
                          delegate: SectionHeaderDelegate(
                            title: _formatDate(group.date),
                          ),
                        ),
                        SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3, // Fixed 3 columns for consistency
                            crossAxisSpacing: 2,
                            mainAxisSpacing: 2,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) {
                              final AssetEntity entity = group.assets[index];
                              return ThumbnailWidget(
                                entity: entity,
                                isFastScrolling: ValueNotifier(false), 
                                heroTagPrefix: 'person_details_${widget.personId}',
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
