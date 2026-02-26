import 'dart:io';
import 'dart:ui';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import '../../providers/photo_provider.dart';
import '../../providers/selection_provider.dart';
import '../../models/photo_group.dart';
import '../../models/gallery_item.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/remote_thumbnail_widget.dart';
import '../widgets/draggable_scroll_icon.dart';
import '../widgets/album_cover_widget.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import 'location_picker_page.dart';
import 'package:latlong2/latlong.dart' as latlong;
import '../widgets/album_picker_dialog.dart';

class AllPhotosPage extends StatefulWidget {
  const AllPhotosPage({super.key});

  @override
  State<AllPhotosPage> createState() => _AllPhotosPageState();
}

class _AllPhotosPageState extends State<AllPhotosPage> with TickerProviderStateMixin {
  // 0 = Month View (less columns, less detail in date)
  // 1 = Day View (more columns, specific date)
  // 2 = Year View
  final ValueNotifier<double> _scaleNotifier = ValueNotifier(1.0);
  GroupMode _groupMode = GroupMode.month;
  final ScrollController _scrollController = ScrollController();

  // Animation & Gesture state
  late AnimationController _zoomAnimateController;
  late Animation<double> _zoomAnimation;
  Alignment _scaleAlignment = Alignment.center;
  Offset _lastFocalPoint = Offset.zero;

  @override
  void initState() {
    super.initState();
    _zoomAnimateController = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200)
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      if (!provider.hasPermission) {
        provider.checkPermission();
      } else {
        provider.fetchRemotePhotos();
      }
    });
  }

  Future<void> _handleUpload() async {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true, type: FileType.image);
      if (result != null && result.files.isNotEmpty) {
          String selectedAlbum = '';
          final controller = TextEditingController();

          await showDialog(
              context: context,
              builder: (context) {
                  return StatefulBuilder(
                    builder: (context, setDialogState) {
                       return Dialog(
                          backgroundColor: Colors.transparent,
                          insetPadding: const EdgeInsets.all(24),
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 420),
                            decoration: BoxDecoration(
                               color: const Color(0xFF121212),
                               borderRadius: BorderRadius.circular(24),
                               border: Border.all(color: Colors.white10, width: 1),
                               boxShadow: const [
                                  BoxShadow(color: Colors.black54, blurRadius: 30, spreadRadius: 10),
                               ]
                            ),
                            padding: const EdgeInsets.all(28),
                            child: SingleChildScrollView(
                               child: Column(
                                   mainAxisSize: MainAxisSize.min,
                                   crossAxisAlignment: CrossAxisAlignment.start,
                                   children: [
                                      const Text('Add to Album', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
                                      const SizedBox(height: 6),
                                      Text('${result.files.length} photo${result.files.length > 1 ? 's' : ''} selected', style: const TextStyle(color: Colors.white54, fontSize: 14)),
                                      const SizedBox(height: 32),

                                      if (Provider.of<PhotoProvider>(context, listen: false).remoteAlbums.isNotEmpty) ...[
                                         const Text('EXISTING ALBUMS', style: TextStyle(color: Colors.white30, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                                         const SizedBox(height: 12),
                                         Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: Provider.of<PhotoProvider>(context, listen: false).remoteAlbums.map((aObj) {
                                                final a = aObj['name'] as String;
                                                final bool isSelected = selectedAlbum == a;
                                                return GestureDetector(
                                                   onTap: () {
                                                      setDialogState(() => selectedAlbum = a);
                                                      controller.text = a;
                                                   },
                                                   child: AnimatedContainer(
                                                      duration: const Duration(milliseconds: 200),
                                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                                      decoration: BoxDecoration(
                                                         color: isSelected ? Colors.white : Colors.white.withOpacity(0.05),
                                                         borderRadius: BorderRadius.circular(20),
                                                         border: Border.all(color: isSelected ? Colors.white : Colors.transparent),
                                                      ),
                                                      child: Text(a, style: TextStyle(color: isSelected ? Colors.black : Colors.white, fontSize: 13, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500)),
                                                   ),
                                                );
                                            }).toList(),
                                         ),
                                         const SizedBox(height: 28),
                                      ],
                                      
                                      const Text('NEW OR CUSTOM ALBUM', style: TextStyle(color: Colors.white30, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                                      const SizedBox(height: 12),
                                      Container(
                                         decoration: BoxDecoration(
                                            color: Colors.white.withOpacity(0.04),
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(color: Colors.white10),
                                         ),
                                         child: TextField(
                                            controller: controller,
                                            style: const TextStyle(color: Colors.white, fontSize: 15),
                                            decoration: const InputDecoration(
                                                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                                hintText: 'Enter album name...',
                                                hintStyle: TextStyle(color: Colors.white30),
                                                border: InputBorder.none,
                                            ),
                                            onChanged: (v) => setDialogState(() => selectedAlbum = v),
                                         ),
                                      ),
                                      const SizedBox(height: 36),
                                      Row(
                                         mainAxisAlignment: MainAxisAlignment.end,
                                         children: [
                                            TextButton(
                                               onPressed: () => Navigator.pop(context), 
                                               style: TextButton.styleFrom(
                                                  foregroundColor: Colors.white54,
                                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                               ),
                                               child: const Text('Cancel', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))
                                            ),
                                            const SizedBox(width: 12),
                                            ElevatedButton(
                                               onPressed: selectedAlbum.trim().isEmpty ? null : () => Navigator.pop(context),
                                               style: ElevatedButton.styleFrom(
                                                  backgroundColor: Colors.white,
                                                  foregroundColor: Colors.black,
                                                  disabledBackgroundColor: Colors.white12,
                                                  disabledForegroundColor: Colors.white30,
                                                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                  elevation: 0,
                                               ),
                                               child: const Text('Upload', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                                            ),
                                         ]
                                      )
                                   ]
                               )
                            )
                          )
                       );
                    }
                  );
              }
          );

          if (selectedAlbum.isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Uploading ${result.files.length} files...')));
              await BackupService().uploadManualFiles(result.files, selectedAlbum);
              if (mounted) {
                 final provider = Provider.of<PhotoProvider>(context, listen: false);
                 await provider.fetchRemotePhotos();
              }
          }
      }
  }

  final ValueNotifier<bool> _isFastScrolling = ValueNotifier(false);

  @override
  void dispose() {
    _scrollController.dispose();
    _scaleNotifier.dispose();
    _zoomAnimateController.dispose();
    _isFastScrolling.dispose();
    super.dispose();
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_zoomAnimateController.isAnimating) return;

    _lastFocalPoint = details.focalPoint;
    final size = MediaQuery.of(context).size;
    final double x = ((details.focalPoint.dx / size.width) - 0.5) * 2;
    final double y = ((details.focalPoint.dy / size.height) - 0.5) * 2;

    setState(() {
      _scaleAlignment = Alignment(x, y);
    });
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (_zoomAnimateController.isAnimating) return;
    _scaleNotifier.value = details.scale;
    _lastFocalPoint = details.focalPoint;
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_zoomAnimateController.isAnimating) return;

    final double scale = _scaleNotifier.value;

    // Ratios based on column counts: Day(3), Month(5), Year(7)
    const double ratioMonthToDay = 5 / 3;
    const double ratioMonthToYear = 5 / 7;
    const double ratioYearToMonth = 7 / 5;
    const double ratioDayToMonth = 3 / 5;

    double targetScale = 1.0;
    GroupMode? nextMode;
    GroupMode currentMode = _groupMode;

    if (scale > 1.25) {
      if (_groupMode == GroupMode.year) {
        nextMode = GroupMode.month;
        targetScale = ratioYearToMonth;
      } else if (_groupMode == GroupMode.month) {
        nextMode = GroupMode.day;
        targetScale = ratioMonthToDay;
      }
    } else if (scale < 0.75) {
      if (_groupMode == GroupMode.day) {
        nextMode = GroupMode.month;
        targetScale = ratioDayToMonth;
      } else if (_groupMode == GroupMode.month) {
        nextMode = GroupMode.year;
        targetScale = ratioMonthToYear;
      }
    }

    if (nextMode != null && nextMode != _groupMode) {
      // 1. Identify Anchor Asset
      final provider = Provider.of<PhotoProvider>(context, listen: false);
      final double currentOffset = _scrollController.hasClients ? _scrollController.offset : 0.0;
      final double focalAbsoluteY = currentOffset + _lastFocalPoint.dy;

      final List<PhotoGroup> currentGroups = _getGroupsForMode(currentMode, provider);
      final int currentCols = _getColsForMode(currentMode);

      final GalleryItem? anchorAsset = _findAssetAtOffset(focalAbsoluteY, currentGroups, currentCols);

      _runScaleAnimation(
          start: scale,
          end: targetScale,
          onComplete: () {
            // 2. Calculate new exact offset
            double newOffset = 0.0;

            if (anchorAsset != null) {
              final List<PhotoGroup> nextGroups = _getGroupsForMode(nextMode!, provider);
              final int nextCols = _getColsForMode(nextMode);

              final double newAssetY = _calculateAssetY(anchorAsset, nextGroups, nextCols);

              // Pin anchor to focal point
              newOffset = newAssetY - _lastFocalPoint.dy;
              if (newOffset < 0) newOffset = 0.0;
            }

            // 3. Update UI & Jump Synchronously
            // We jump immediately to prevent the 1-frame jitter.
            // Flutter allows jumpTo during build/layout phase updates if handled carefully.
            setState(() {
              _groupMode = nextMode!;
              _scaleNotifier.value = 1.0;
            });

            if (_scrollController.hasClients) {
              // We attempt to jump immediately.
              // Note: detailed clamping might be off until layout, but usually
              // switching Day->Month or Month->Day expands content or keeps it similar enough
              _scrollController.jumpTo(newOffset);
            }
          }
      );
    } else {
      _runScaleAnimation(start: scale, end: 1.0);
    }
  }

  // --- Helpers for Apple-Style Zoom Math ---

  int _getColsForMode(GroupMode mode) {
    switch (mode) {
      case GroupMode.day: return 3;
      case GroupMode.month: return 5;
      case GroupMode.year: return 7;
    }
  }

  List<PhotoGroup> _getGroupsForMode(GroupMode mode, PhotoProvider provider) {
    switch (mode) {
      case GroupMode.day: return provider.groupedByDay;
      case GroupMode.month: return provider.groupedByMonth;
      case GroupMode.year: return provider.groupedByYear;
    }
  }

  GalleryItem? _findAssetAtOffset(double absoluteY, List<PhotoGroup> groups, int cols) {
    double yCursor = 0;
    const double headerHeight = 50.0;
    final double rowHeight = (MediaQuery.of(context).size.width / cols) + 2.0;

    for (final group in groups) {
      // Header
      if (absoluteY >= yCursor && absoluteY < yCursor + headerHeight) {
        return group.items.isNotEmpty ? group.items.first : null; // Hit header, return first
      }
      yCursor += headerHeight;

      final int rows = (group.items.length / cols).ceil();
      final double groupBodyHeight = rows * rowHeight;

      if (absoluteY < yCursor + groupBodyHeight) {
        // It's in this group grid
        final double localY = absoluteY - yCursor;
        final int row = (localY / rowHeight).floor();
        // Assume middle column for stability? Or just start of row.
        // Start of row is safest anchor.
        final int index = row * cols;
        if (index < group.items.length) return group.items[index];
        return group.items.last;
      }
      yCursor += groupBodyHeight;
    }
    return null;
  }

  double _calculateAssetY(GalleryItem target, List<PhotoGroup> groups, int cols) {
    double yCursor = 0;
    const double headerHeight = 50.0;
    final double rowHeight = (MediaQuery.of(context).size.width / cols) + 2.0;

    for (final group in groups) {
      // Is target in this group?
      int index = group.items.indexOf(target);
      if (index != -1) {
        // Found
        yCursor += headerHeight;
        final int row = index ~/ cols;
        yCursor += row * rowHeight;
        return yCursor;
      }

      // Add this group's height
      yCursor += headerHeight;
      final int rows = (group.items.length / cols).ceil();
      yCursor += rows * rowHeight;
    }
    return 0.0; // Should not happen if asset exists
  }

  void _runScaleAnimation({required double start, required double end, VoidCallback? onComplete}) {
    _zoomAnimation = Tween<double>(begin: start, end: end).animate(
        CurvedAnimation(parent: _zoomAnimateController, curve: Curves.easeInOutQuad)
    );

    _zoomAnimateController.reset();
    _zoomAnimateController.forward().then((_) {
      if (onComplete != null) onComplete();
    });

    _zoomAnimation.addListener(() {
      _scaleNotifier.value = _zoomAnimation.value;
    });
  }

  String _formatDate(DateTime date, GroupMode mode) {
    if (mode == GroupMode.year) {
      return DateFormat('yyyy').format(date);
    } else if (mode == GroupMode.month) {
      return DateFormat('MMMM yyyy').format(date);
    } else {
      final now = DateTime.now();
      if (date.year == now.year && date.month == now.month && date.day == now.day) {
        return 'Today';
      }
      if (date.year == now.year && date.month == now.month && date.day == now.day - 1) {
        return 'Yesterday';
      }
      return DateFormat('EEE, d MMM').format(date);
    }
  }

  Widget _buildAlbumsRow(PhotoProvider provider) {
     final bool isWide = MediaQuery.of(context).size.width > 600;
     if (!isWide && !kIsWeb) return const SizedBox.shrink();
     if (provider.isLoading && provider.remoteAlbums.isEmpty) return const SizedBox.shrink();

     final albums = provider.remoteAlbums;

     return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
           const Padding(
             padding: EdgeInsets.fromLTRB(24, 16, 24, 12),
             child: Text('Albums', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
           ),
           SizedBox(
             height: 90,
             child: albums.isEmpty
                 ? Padding(
                     padding: const EdgeInsets.symmetric(horizontal: 24.0),
                     child: Container(
                        width: 120,
                        decoration: BoxDecoration(
                           color: Colors.transparent,
                           borderRadius: BorderRadius.circular(8),
                           border: Border.all(color: Colors.white24, width: 1.5), // Mock Dotted Outline
                        ),
                        child: const Center(
                           child: Column(
                               mainAxisSize: MainAxisSize.min,
                               children: [
                                  Icon(Icons.add_photo_alternate_outlined, color: Colors.white38, size: 20),
                                  SizedBox(height: 6),
                                  Text('Create an album', style: TextStyle(color: Colors.white38, fontSize: 11, fontWeight: FontWeight.w500))
                               ]
                           )
                        ),
                     ),
                   )
                 : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    scrollDirection: Axis.horizontal,
                    itemCount: albums.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, i) {
                       final albumObj = albums[i];
                       final albumName = albumObj['name'] as String;
                       final thumbUrl = albumObj['cover_image_url'] as String? ?? '';

                       return GestureDetector(
                          onTap: () => context.push('/albums/${Uri.encodeComponent(albumName)}'),
                          child: Container(
                             width: 120,
                             decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                             ),
                             clipBehavior: Clip.antiAlias,
                             child: AlbumCoverWidget(thumbUrl: thumbUrl, albumName: albumName),
                          ),
                       );
                    },
                 ),
           ),
           const Padding(
             padding: EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
             child: Divider(color: Colors.white10, height: 1),
           ),
        ],
     );
  }

  Widget _buildAllHeader(int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('All Memories', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5)),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: IconButton(onPressed: (){}, icon: const Icon(Icons.more_horiz, color: Colors.white70, size: 20)),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text('$count memories', style: const TextStyle(color: Colors.white54, fontSize: 13)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black, // Revert to pure black
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Consumer<SelectionProvider>(
          builder: (context, selection, child) {
            if (selection.isSelectionMode) {
              return AppBar(
                backgroundColor: Colors.black,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => selection.clearSelection(),
                ),
                title: Text('${selection.selectedItems.length} selected', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              );
            }
            return AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              leading: Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.menu_rounded, color: Colors.white70),
                  onPressed: () {
                     context.push('/settings');
                  },
                ),
              ),
              title: Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 600),
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(30), // Modern Pill Search Bar
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(Icons.search, color: Colors.white54, size: 20),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Search for albums, dates, descriptions, ...',
                          style: TextStyle(color: Colors.white54, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (MediaQuery.of(context).size.width > 600)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black38,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Ctrl + K', style: TextStyle(color: Colors.white54, fontSize: 10, fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (kIsWeb || (!kIsWeb && !Platform.isAndroid)) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: Center(
                      child: IconButton(
                        onPressed: () => context.read<PhotoProvider>().refresh(),
                        icon: const Icon(Icons.refresh_rounded, color: Colors.white70, size: 22),
                        tooltip: 'Refresh cloud data',
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 16.0),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: _handleUpload,
                        icon: const Icon(Icons.upload_rounded, size: 18, color: Colors.white),
                        label: const Text('Upload', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white24),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                          backgroundColor: Colors.white.withOpacity(0.05),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
      body: Stack(
        children: [
          Consumer<PhotoProvider>(
            builder: (context, provider, child) {
              if (provider.isLoading && provider.allAssets.isEmpty && provider.remoteImages.isEmpty) {
                return const Center(child: CircularProgressIndicator(color: Colors.white70));
              }
               if (provider.groupedByDay.isEmpty && provider.groupedByMonth.isEmpty && provider.groupedByYear.isEmpty) {
                return const Center(child: Text('No photos found.'));
              }

              List<PhotoGroup> groups;
              int crossAxisCount;
              final double screenWidth = MediaQuery.of(context).size.width;
              final bool isMobile = screenWidth < 600;

              switch (_groupMode) {
                case GroupMode.year:
                  groups = provider.groupedByYear;
                  crossAxisCount = isMobile ? 6 : 8;
                  break;
                case GroupMode.month:
                  groups = provider.groupedByMonth;
                  crossAxisCount = isMobile ? 4 : 7;
                  break;
                case GroupMode.day:
                default:
                  groups = provider.groupedByDay;
                  crossAxisCount = isMobile ? 3 : 6;
                  break;
              }

              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: RefreshIndicator(
                  onRefresh: () => provider.refresh(),
                  color: Colors.white,
                  backgroundColor: Colors.grey[900],
                  child: DraggableScrollIcon(
                    controller: _scrollController,
                    backgroundColor: Colors.grey[900]!.withOpacity(0.8),
                    onDragStart: () => _isFastScrolling.value = true,
                    onDragEnd: () => _isFastScrolling.value = false,
                    child: CustomScrollView(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                        slivers: [
                          SliverToBoxAdapter(
                            child: _buildAlbumsRow(provider),
                          ),
                          SliverToBoxAdapter(
                            child: _buildAllHeader(provider.allAssets.length + provider.remoteImages.length),
                          ),
                          for (var group in groups) ...[
                            SliverPersistentHeader(
                              pinned: false,
                              delegate: SectionHeaderDelegate(
                                title: _formatDate(group.date, _groupMode),
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
                                  if (item.type == GalleryItemType.local) {
                                     return ThumbnailWidget(
                                       entity: item.local!,
                                       isFastScrolling: _isFastScrolling,
                                       heroTagPrefix: 'all_photos',
                                     );
                                  } else {
                                     return RemoteThumbnailWidget(
                                        image: item.remote! 
                                        // No fast scrolling optimized signal passed yet, but loads async
                                        // RemoteThumbnailWidget handles loading state
                                     );
                                  }
                                },
                                childCount: group.items.length,
                              ),
                            ),
                           ),
                          ]
                        ],
                      ),
                    ),
                ),
                );
              },
          ),
          
          // Modern Floating Action Bar
          Consumer<SelectionProvider>(
            builder: (context, selection, child) {
              if (!selection.isSelectionMode || selection.selectedItems.isEmpty) return const SizedBox.shrink();

              return Positioned(
                bottom: 30, // Hover above bottom bar
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
                               
                               // Gather local albums + distinct remote albums
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
                            _buildActionIcon(Icons.pin_drop_rounded, 'Location', () async {
                               final sp = Provider.of<SelectionProvider>(context, listen: false);
                               final pp = Provider.of<PhotoProvider>(context, listen: false);
                               final items = List<GalleryItem>.from(sp.selectedItems);
                               sp.clearSelection();
                               
                               // Calculate an initial center if the first selected item has one
                               latlong.LatLng? initial;
                               if (items.isNotEmpty) {
                                  final first = items.first;
                                  if (first.type == GalleryItemType.local) {
                                     initial = pp.locationCache[first.local!.id] ?? 
                                               (first.local!.latitude != null ? latlong.LatLng(first.local!.latitude!, first.local!.longitude!) : null);
                                  } else {
                                     if (first.remote!.latitude != 0) {
                                        initial = latlong.LatLng(first.remote!.latitude, first.remote!.longitude);
                                     }
                                  }
                               }

                               final result = await Navigator.push<latlong.LatLng?>(
                                  context, 
                                  MaterialPageRoute(builder: (_) => LocationPickerPage(initialLocation: initial))
                               );
                               
                               if (result != null) {
                                   await pp.updateLocationForSelected(items, result.latitude, result.longitude);
                               }
                            }),
                            const SizedBox(width: 8),
                            Container(width: 1, height: 30, color: Colors.white12), // Divider
                            const SizedBox(width: 8),
                            _buildActionIcon(Icons.delete_sweep_rounded, 'Delete', () async {
                              final sp = Provider.of<SelectionProvider>(context, listen: false);
                              final pp = Provider.of<PhotoProvider>(context, listen: false);
                              // 1. Copy selection items before clearing
                              final items = List<GalleryItem>.from(sp.selectedItems);
                              // 2. Clear visually
                              sp.clearSelection();
                              // 3. Delete from backend/local gracefully
                              await pp.deleteSelectedPhotos(context, items);
                            }, color: Colors.redAccent),
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
      ),
      bottomNavigationBar: ValueListenableBuilder<String?>(
        valueListenable: Provider.of<PhotoProvider>(context, listen: false).backgroundStatus,
        builder: (context, status, child) {
          if (status == null) return const SizedBox.shrink();
          return Container(
            color: Theme.of(context).bottomAppBarTheme.color ?? Colors.black87,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  )
                ),
              ],
            ),
          );
        },
      ),
    );
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
}
