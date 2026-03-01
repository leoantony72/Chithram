import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class ScaffoldWithNavBar extends StatefulWidget {
  const ScaffoldWithNavBar({
    required this.navigationShell,
    super.key,
  });

  final StatefulNavigationShell navigationShell;

  @override
  State<ScaffoldWithNavBar> createState() => _ScaffoldWithNavBarState();
}

class _ScaffoldWithNavBarState extends State<ScaffoldWithNavBar> {
  void _onTap(BuildContext context, int index) {
    widget.navigationShell.goBranch(
      index,
      initialLocation: index == widget.navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isMobile = constraints.maxWidth < 650;
          return Stack(
            children: [
              // 1. The main content area
              // If we're on desktop, push it right so it doesn't overlap the sidebar
              Positioned.fill(
                left: isMobile ? 0 : 80, // Padding for the sidebar
                child: widget.navigationShell,
              ),

              // 2. The Navigation UI
              if (isMobile)
                _buildMobileNavBar(context)
              else
                _buildDesktopSideBar(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDesktopSideBar(BuildContext context) {
    return Positioned(
      left: 16,
      top: 16,
      bottom: 16,
      width: 64,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black45,
                  blurRadius: 30,
                  offset: Offset(4, 0),
                )
              ],
            ),
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _NavItem(
                  icon: Icons.photo_library_rounded,
                  label: 'Photos',
                  isSelected: widget.navigationShell.currentIndex == 0,
                  onTap: () => _onTap(context, 0),
                  isVertical: true,
                ),
                const SizedBox(height: 24),
                _NavItem(
                  icon: Icons.face_retouching_natural_rounded,
                  label: 'People',
                  isSelected: widget.navigationShell.currentIndex == 1,
                  onTap: () => _onTap(context, 1),
                  isVertical: true,
                ),
                const SizedBox(height: 24),
                _NavItem(
                  icon: Icons.auto_awesome_mosaic_rounded,
                  label: 'Albums',
                  isSelected: widget.navigationShell.currentIndex == 2,
                  onTap: () => _onTap(context, 2),
                  isVertical: true,
                ),
                const SizedBox(height: 24),
                _NavItem(
                  icon: Icons.flight_takeoff_rounded,
                  label: 'Journeys',
                  isSelected: widget.navigationShell.currentIndex == 3,
                  onTap: () => _onTap(context, 3),
                  isVertical: true,
                ),
                const SizedBox(height: 24),
                _NavItem(
                  icon: Icons.share_rounded,
                  label: 'Shared',
                  isSelected: widget.navigationShell.currentIndex == 4,
                  onTap: () => _onTap(context, 4),
                  isVertical: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobileNavBar(BuildContext context) {
    return Positioned(
      bottom: 24,
      left: 24,
      right: 24,
      child: SafeArea(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(40),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.08),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black54,
                    blurRadius: 40,
                    offset: Offset(0, 10),
                  )
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _NavItem(
                    icon: Icons.photo_library_rounded,
                    label: 'Photos',
                    isSelected: widget.navigationShell.currentIndex == 0,
                    onTap: () => _onTap(context, 0),
                    isVertical: false,
                  ),
                  _NavItem(
                    icon: Icons.face_retouching_natural_rounded,
                    label: 'People',
                    isSelected: widget.navigationShell.currentIndex == 1,
                    onTap: () => _onTap(context, 1),
                    isVertical: false,
                  ),
                  _NavItem(
                    icon: Icons.auto_awesome_mosaic_rounded,
                    label: 'Albums',
                    isSelected: widget.navigationShell.currentIndex == 2,
                    onTap: () => _onTap(context, 2),
                    isVertical: false,
                  ),
                  _NavItem(
                    icon: Icons.flight_takeoff_rounded,
                    label: 'Journeys',
                    isSelected: widget.navigationShell.currentIndex == 3,
                    onTap: () => _onTap(context, 3),
                    isVertical: false,
                  ),
                  _NavItem(
                    icon: Icons.share_rounded,
                    label: 'Shared',
                    isSelected: widget.navigationShell.currentIndex == 4,
                    onTap: () => _onTap(context, 4),
                    isVertical: false,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isVertical;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.isVertical,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  bool _isHovering = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 150),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isSelected ? Colors.white : Colors.white54;
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTapDown: (_) => _controller.forward(),
        onTapUp: (_) {
          _controller.reverse();
          widget.onTap();
        },
        onTapCancel: () => _controller.reverse(),
        behavior: HitTestBehavior.opaque,
        child: AnimatedBuilder(
          animation: _scaleAnimation,
          builder: (context, child) => Transform.scale(
            scale: _scaleAnimation.value,
            child: child,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: widget.isVertical ? 4 : (widget.isSelected ? 16 : 12),
              vertical: widget.isVertical ? (widget.isSelected ? 16 : 12) : 8,
            ),
            decoration: BoxDecoration(
              color: widget.isSelected 
                  ? Colors.white.withOpacity(0.15) 
                  : (_isHovering ? Colors.white.withOpacity(0.05) : Colors.transparent),
              borderRadius: BorderRadius.circular(widget.isVertical ? 20 : 24),
              border: Border.all(
                  color: widget.isSelected 
                     ? Colors.white.withOpacity(0.2) 
                     : Colors.transparent,
              )
            ),
            child: widget.isVertical
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: color, size: 22),
                      if (widget.isSelected) ...[
                        const SizedBox(height: 6),
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: color,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ]
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(widget.icon, color: color, size: 22),
                      if (widget.isSelected) ...[
                        const SizedBox(width: 8),
                        Text(
                          widget.label,
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ]
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
