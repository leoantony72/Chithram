import 'package:flutter/material.dart';

class DraggableScrollIcon extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  final Color? color;
  final Color? backgroundColor;

  const DraggableScrollIcon({
    super.key,
    required this.controller,
    required this.child,
    this.color,
    this.backgroundColor,
  });

  @override
  State<DraggableScrollIcon> createState() => _DraggableScrollIconState();
}

class _DraggableScrollIconState extends State<DraggableScrollIcon> {
  double _scrollProgress = 0.0;
  bool _isDragging = false;
  
  // Height of the scroll handle area
  final double _handleHeight = 60.0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateProgress);
  }

  @override
  void didUpdateWidget(DraggableScrollIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller) {
      oldWidget.controller.removeListener(_updateProgress);
      widget.controller.addListener(_updateProgress);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateProgress);
    super.dispose();
  }

  void _updateProgress() {
    if (!_isDragging && widget.controller.hasClients) {
      final maxScroll = widget.controller.position.maxScrollExtent;
      final currentScroll = widget.controller.position.pixels;
      if (maxScroll > 0) {
        setState(() {
          _scrollProgress = (currentScroll / maxScroll).clamp(0.0, 1.0);
        });
      }
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double trackHeight) {
    setState(() {
      _isDragging = true;
      // Calculate new progress based on drag position
      // Available track height for the handle center is trackHeight - _handleHeight
      final double effectiveHeight = trackHeight - _handleHeight;
       if (effectiveHeight <= 0) return;
       
      // We need to map the local position to progress
      // But we simple add delta to current progress
      
      final delta = details.delta.dy;
      final change = delta / effectiveHeight;
      
      _scrollProgress = (_scrollProgress + change).clamp(0.0, 1.0);
      
      if (widget.controller.hasClients) {
         final maxScroll = widget.controller.position.maxScrollExtent;
         widget.controller.jumpTo(maxScroll * _scrollProgress);
      }
    });
  }
  
  void _onVerticalDragEnd(DragEndDetails details) {
    setState(() {
      _isDragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackHeight = constraints.maxHeight;
        final top = _scrollProgress * (trackHeight - _handleHeight);

        return Stack(
          children: [
            widget.child, // The ScrollViewContent
            
            // The Scroll Handle
            Positioned(
              right: 4,
              top: top,
              child: GestureDetector(
                onVerticalDragUpdate: (details) => _onVerticalDragUpdate(details, trackHeight),
                onVerticalDragEnd: _onVerticalDragEnd,
                child: Container(
                  height: _handleHeight,
                  width: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: widget.backgroundColor ?? Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Icon(
                    Icons.unfold_more,
                    color: widget.color ?? Colors.white,
                    size: 24,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
