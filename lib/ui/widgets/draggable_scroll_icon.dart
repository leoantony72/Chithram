import 'package:flutter/material.dart';
import '../../models/photo_group.dart';

/// A draggable scroll handle that shows:
///   • A floating **date pill** next to the thumb tracking the current position
///   • Fixed **year markers** on the scroll track at each year boundary
///
/// Inspired by ente photos' `CustomScrollBar` / `positionToTitleMap` pattern.
class DraggableScrollIcon extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  final Color? color;
  final Color? backgroundColor;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  /// The currently displayed groups in scroll order. Optional — when null,
  /// no year markers or date pill are shown.
  final List<PhotoGroup>? groups;

  /// Formats the group date into the label shown next to the thumb.
  final String Function(DateTime date)? labelFormatter;

  /// Cross-axis tile count — needed to compute each group's pixel height.
  final int crossAxisCount;

  const DraggableScrollIcon({
    super.key,
    required this.controller,
    required this.child,
    this.groups,
    this.labelFormatter,
    this.crossAxisCount = 4,
    this.color,
    this.backgroundColor,
    this.onDragStart,
    this.onDragEnd,
  });

  @override
  State<DraggableScrollIcon> createState() => _DraggableScrollIconState();
}

class _DraggableScrollIconState extends State<DraggableScrollIcon>
    with SingleTickerProviderStateMixin {
  double _scrollProgress = 0.0;
  bool _isDragging = false;
  bool _isScrolling = false;

  // How tall the draggable handle pill is
  static const double _handleHeight = 56.0;
  // Header height per group (matches SectionHeaderDelegate)
  static const double _headerHeight = 50.0;
  // Vertical padding around each SliverGrid (top + bottom = 24)
  static const double _groupPadding = 24.0;

  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  /// fraction → label, built once the groups/crossAxisCount change
  Map<double, String> _positionToLabel = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onScroll);

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildMap());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildMap());
  }

  @override
  void didUpdateWidget(DraggableScrollIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (oldWidget.groups != widget.groups ||
        oldWidget.crossAxisCount != widget.crossAxisCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _rebuildMap());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _fadeController.dispose();
    super.dispose();
  }

  // ─── Helpers ──────────────────────────────────────────────────────────────

  /// Computes the total scrollable content height given the current viewport.
  /// We approximate tile size from screen width — same formula as all_photos_page.
  double _computeTotalHeight(double viewportWidth) {
    final groups = widget.groups;
    if (groups == null) return 0;
    final tileSize = viewportWidth / widget.crossAxisCount;
    final rowHeight = tileSize + 2; // +2 for spacing
    double total = 0;
    for (final g in groups) {
      total += _headerHeight;
      total += _groupPadding;
      final rows = (g.items.length / widget.crossAxisCount).ceil();
      total += rows * rowHeight;
    }
    return total;
  }

  /// Builds a map of scroll-fraction → label for each year boundary.
  void _rebuildMap() {
    if (!mounted) return;
    final groups = widget.groups;
    final labelFormatter = widget.labelFormatter;
    if (groups == null || labelFormatter == null) return;
    final mq = MediaQuery.of(context);
    final viewportWidth = mq.size.width;
    final totalHeight = _computeTotalHeight(viewportWidth);
    if (totalHeight <= 0) return;

    final tileSize = viewportWidth / widget.crossAxisCount;
    final rowHeight = tileSize + 2;

    final map = <double, String>{};
    double cursor = 0;
    int? lastYear;

    for (final g in groups) {
      final year = g.date.year;
      if (lastYear != year) {
        lastYear = year;
        // Record the fraction where this year starts
        final fraction = (cursor / totalHeight).clamp(0.0, 1.0);
        map[fraction] = year.toString();
      }
      cursor += _headerHeight + _groupPadding;
      final rows = (g.items.length / widget.crossAxisCount).ceil();
      cursor += rows * rowHeight;
    }

    if (mounted) {
      setState(() => _positionToLabel = map);
    }
  }

  void _onScroll() {
    if (_isDragging) return;
    if (!widget.controller.hasClients) return;
    final maxScroll = widget.controller.position.maxScrollExtent;
    if (maxScroll <= 0) return;

    final progress =
        (widget.controller.position.pixels / maxScroll).clamp(0.0, 1.0);
    setState(() {
      _scrollProgress = progress;
      _isScrolling = true;
    });

    _fadeController.forward();

    // Auto-hide the labels after scrolling stops
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && !_isDragging && _isScrolling) {
        _isScrolling = false;
        _fadeController.reverse();
      }
    });
  }

  void _onDragUpdate(DragUpdateDetails details, double trackHeight) {
    if (!_isDragging) {
      widget.onDragStart?.call();
      _fadeController.forward();
    }
    final effective = trackHeight - _handleHeight;
    if (effective <= 0) return;
    final newProgress =
        (_scrollProgress + details.delta.dy / effective).clamp(0.0, 1.0);
    setState(() {
      _isDragging = true;
      _scrollProgress = newProgress;
    });
    if (widget.controller.hasClients) {
      final maxScroll = widget.controller.position.maxScrollExtent;
      widget.controller.jumpTo(maxScroll * _scrollProgress);
    }
  }

  void _onDragEnd(DragEndDetails _) {
    widget.onDragEnd?.call();
    setState(() => _isDragging = false);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted && !_isDragging) _fadeController.reverse();
    });
  }

  /// Returns the label closest to the current scroll position.
  String _activeLabel() {
    if (_positionToLabel.isEmpty) return '';
    String best = _positionToLabel.values.last;
    double bestDiff = double.infinity;
    for (final entry in _positionToLabel.entries) {
      final diff = (_scrollProgress - entry.key).abs();
      // Take the nearest label that is AT OR BEFORE the current position
      if (entry.key <= _scrollProgress + 0.001 && diff < bestDiff) {
        bestDiff = diff;
        best = entry.value;
      }
    }
    return best;
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        final thumbTop = _scrollProgress * (trackHeight - _handleHeight);
        final label = _activeLabel();

        return Stack(
          clipBehavior: Clip.none,
          children: [
            // ── 1. Content ─────────────────────────────────────────────
            widget.child,

            // ── 2. Year track markers (fixed, aligned to their fraction) ─
            FadeTransition(
              opacity: _fadeAnimation,
              child: IgnorePointer(
                child: Stack(
                  children: _positionToLabel.entries.map((entry) {
                    final markerY =
                        entry.key * trackHeight;
                    return Positioned(
                      right: 52, // Left of the handle
                      top: markerY.clamp(0.0, trackHeight - 20),
                      child: _YearMarker(label: entry.value),
                    );
                  }).toList(),
                ),
              ),
            ),

            // ── 3. Draggable handle + floating active date pill ─────────
            Positioned(
              right: 4,
              top: thumbTop,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Floating date pill (visible while dragging or scrolling)
                  FadeTransition(
                    opacity: _fadeAnimation,
                    child: IgnorePointer(
                      child: _DatePill(label: label),
                    ),
                  ),
                  const SizedBox(width: 4),
                  // The actual draggable handle
                  GestureDetector(
                    onVerticalDragUpdate: (d) => _onDragUpdate(d, trackHeight),
                    onVerticalDragEnd: _onDragEnd,
                    child: _ScrollHandle(
                      isDragging: _isDragging,
                      color: widget.color,
                      backgroundColor: widget.backgroundColor,
                      height: _handleHeight,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// The floating pill showing the active date/year next to the scroll thumb.
class _DatePill extends StatelessWidget {
  final String label;
  const _DatePill({required this.label});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xCC1C1C1E), // semi-transparent dark surface
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

/// A small label pinned at a fixed scroll fraction (year boundary).
class _YearMarker extends StatelessWidget {
  final String label;
  const _YearMarker({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/// The draggable thumb handle itself.
class _ScrollHandle extends StatelessWidget {
  final bool isDragging;
  final Color? color;
  final Color? backgroundColor;
  final double height;

  const _ScrollHandle({
    required this.isDragging,
    required this.height,
    this.color,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: height,
      width: isDragging ? 44 : 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDragging
            ? (backgroundColor ?? Colors.white).withOpacity(0.18)
            : (backgroundColor ?? Colors.black.withOpacity(0.55)),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDragging ? Colors.white38 : Colors.white24,
          width: isDragging ? 1.5 : 1,
        ),
      ),
      child: Icon(
        Icons.unfold_more_rounded,
        color: color ?? Colors.white,
        size: isDragging ? 22 : 20,
      ),
    );
  }
}
