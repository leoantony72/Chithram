import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:intl/intl.dart';
import '../../providers/photo_provider.dart';
import '../../models/photo_group.dart';
import '../widgets/section_header_delegate.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/draggable_scroll_icon.dart';

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
      }
    });
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
      
      final AssetEntity? anchorAsset = _findAssetAtOffset(focalAbsoluteY, currentGroups, currentCols);

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

  AssetEntity? _findAssetAtOffset(double absoluteY, List<PhotoGroup> groups, int cols) {
    double yCursor = 0;
    const double headerHeight = 50.0;
    final double itemHeight = (MediaQuery.of(context).size.width / cols); // spacing included in height calc usually? 
    // Actually gridDelegate uses crossAxisSpacing. The item height is (width/cols). 
    // MainAxisSpacing adds to total height.
    // Let's approximate: height + 2.0 spacing.
    final double rowHeight = (MediaQuery.of(context).size.width / cols) + 2.0;

    for (final group in groups) {
      // Header
      if (absoluteY >= yCursor && absoluteY < yCursor + headerHeight) {
         return group.assets.isNotEmpty ? group.assets.first : null; // Hit header, return first
      }
      yCursor += headerHeight;
      
      final int rows = (group.assets.length / cols).ceil();
      final double groupBodyHeight = rows * rowHeight;
      
      if (absoluteY < yCursor + groupBodyHeight) {
        // It's in this group grid
        final double localY = absoluteY - yCursor;
        final int row = (localY / rowHeight).floor();
        // Assume middle column for stability? Or just start of row.
        // Start of row is safest anchor.
        final int index = row * cols; 
        if (index < group.assets.length) return group.assets[index];
        return group.assets.last;
      }
      yCursor += groupBodyHeight;
    }
    return null;
  }

  double _calculateAssetY(AssetEntity target, List<PhotoGroup> groups, int cols) {
    double yCursor = 0;
    const double headerHeight = 50.0;
    final double rowHeight = (MediaQuery.of(context).size.width / cols) + 2.0;

    for (final group in groups) {
      // Is target in this group?
      // For speed, check date of group vs date of asset? 
      // Or just simple list check. List check is O(N) but safer.
      // Optimization: assets are usually sorted time desc. 
      // But let's just 'contains' or manual loop.
      // actually 'indexOf' is O(N).
       
      // Check bounds first to skip?
      // if (target.createDateTime ...) - logic is complex due to group definitions.
      // Let's just trust indexOf for now, typical gallery < 1000 groups, < 50 items/group avg.
      
      int index = group.assets.indexOf(target);
      if (index != -1) {
         // Found
         yCursor += headerHeight;
         final int row = index ~/ cols;
         yCursor += row * rowHeight;
         return yCursor;
      }
      
      // Add this group's height
      yCursor += headerHeight;
      final int rows = (group.assets.length / cols).ceil();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All Photos')),
      body: Consumer<PhotoProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading && provider.allAssets.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!provider.hasPermission) {
             return Center(
              child: ElevatedButton(
                onPressed: provider.checkPermission,
                child: const Text('Grant Permission'),
              ),
            );
          }
           if (provider.allAssets.isEmpty) {
            return const Center(child: Text('No photos found.'));
          }

          List<PhotoGroup> groups;
          int crossAxisCount;

          switch (_groupMode) {
            case GroupMode.year:
              groups = provider.groupedByYear;
              crossAxisCount = 7;
              break;
            case GroupMode.month:
              groups = provider.groupedByMonth;
              crossAxisCount = 5;
              break;
            case GroupMode.day:
            default:
              groups = provider.groupedByDay;
              crossAxisCount = 3;
              break;
          }

          return GestureDetector(
            behavior: HitTestBehavior.translucent, 
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: DraggableScrollIcon(
              controller: _scrollController,
              backgroundColor: Colors.grey[900]!.withOpacity(0.8),
              onDragStart: () => _isFastScrolling.value = true,
              onDragEnd: () => _isFastScrolling.value = false,
              child: ValueListenableBuilder<double>(
                valueListenable: _scaleNotifier,
                builder: (context, scale, child) {
                  return Transform.scale(
                    scale: scale,
                    alignment: _scaleAlignment, 
                    child: child,
                  );
                },
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const BouncingScrollPhysics(),
                  slivers: [
                     for (var group in groups) ...[
                       SliverPersistentHeader(
                         pinned: false,
                         delegate: SectionHeaderDelegate(
                           title: _formatDate(group.date, _groupMode),
                         ),
                       ),
                       SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final AssetEntity entity = group.assets[index];
                             return ThumbnailWidget(
                               entity: entity, 
                               isFastScrolling: _isFastScrolling,
                               heroTagPrefix: 'all_photos',
                             );
                          },
                          childCount: group.assets.length,
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
}
