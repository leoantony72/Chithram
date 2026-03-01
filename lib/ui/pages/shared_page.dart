import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../services/share_service.dart';

class SharedPage extends StatefulWidget {
  const SharedPage({super.key});

  @override
  State<SharedPage> createState() => _SharedPageState();
}

class _SharedPageState extends State<SharedPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<ShareItem> _withMe = [];
  List<ShareItem> _byMe = [];
  bool _loading = true;
  int _activeTab = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() => _activeTab = _tabController.index));
    _loadShares();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadShares() async {
    setState(() => _loading = true);
    final withMe = await ShareService().listSharesWithMe();
    final byMe = await ShareService().listSharesByMe();
    if (mounted) {
      setState(() {
        _withMe = withMe.where((s) => !(s.isOneTime && s.isViewed)).toList();
        _byMe = byMe.where((s) => !(s.isOneTime && s.isViewed)).toList();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 48, 28, 32),
              child: Row(
                children: [
                  const Text(
                    'SHARED',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      letterSpacing: 3.0,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _loading ? null : _loadShares,
                    child: const Icon(Icons.refresh_sharp, color: Colors.white, size: 20),
                  ),
                ],
              ),
            ),
            // Minimalist Tabs
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  _MinimalTab(
                    label: 'WITH ME',
                    isActive: _activeTab == 0,
                    onTap: () => _tabController.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.linear),
                  ),
                  const SizedBox(width: 32),
                  _MinimalTab(
                    label: 'BY ME',
                    isActive: _activeTab == 1,
                    onTap: () => _tabController.animateTo(1, duration: const Duration(milliseconds: 200), curve: Curves.linear),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 28),
              child: Divider(color: Colors.white12, height: 1, thickness: 0.5),
            ),
            const SizedBox(height: 20),
            // Content
            Expanded(
              child: _loading
                  ? const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: Colors.white24,
                        ),
                      ),
                    )
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildShareList(_withMe, isWithMe: true),
                        _buildShareList(_byMe, isWithMe: false),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShareList(List<ShareItem> items, {required bool isWithMe}) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.03),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Icon(Icons.auto_awesome_motion_rounded, size: 56, color: Colors.white.withOpacity(0.15)),
            ),
            const SizedBox(height: 24),
            Text(
              isWithMe ? 'No shares yet' : 'Nothing shared',
              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 17, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              isWithMe ? 'Photos shared with you will appear here' : 'Share a photo to get started',
              style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 14),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossCount = constraints.maxWidth > 600 ? 4 : 3;
        return GridView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossCount,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 0.82,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final share = items[index];
            return _ShareCard(
              share: share,
              isWithMe: isWithMe,
              onTap: () => _openSharedPhoto(share),
              onRevoke: isWithMe ? null : () => _revokeShare(share),
            );
          },
        );
      },
    );
  }

  Future<void> _openSharedPhoto(ShareItem share) async {
    if (share.isOneTime && share.isViewed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('THIS ONE-TIME SHARE HAS ALREADY BEEN VIEWED', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF1A1A1A),
        ),
      );
      return;
    }

    final bytes = await ShareService().fetchSharedImage(share.id);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('COULD NOT LOAD SHARED PHOTO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Color(0xFF1A1A1A),
        ),
      );
      return;
    }

    final refresh = await context.push<bool>('/shared_viewer', extra: {
      'bytes': bytes,
      'share': share,
      'senderUsername': share.senderUsername ?? share.senderId,
    });

    if (refresh == true) {
      _loadShares();
    }
  }

  Future<void> _revokeShare(ShareItem share) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.black,
      builder: (ctx) => _RevokeSheet(
        onRevoke: () => Navigator.pop(ctx, true), 
        onCancel: () => Navigator.pop(ctx, false)
      ),
    );
    if (ok == true) {
      await ShareService().revokeShare(share.id);
      _loadShares();
    }
  }
}

class _MinimalTab extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _MinimalTab({required this.label, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: isActive ? Colors.white : Colors.white24,
              fontSize: 10,
              fontWeight: FontWeight.w900,
              letterSpacing: 2.0,
            ),
          ),
          if (isActive) ...[
            const SizedBox(height: 4),
            Container(width: 12, height: 1.5, color: Colors.white),
          ],
        ],
      ),
    );
  }
}

// Removed _TabPill and _GlassButton as they are replaced by _MinimalTab and simple icons

class _ShareCard extends StatefulWidget {
  final ShareItem share;
  final bool isWithMe;
  final VoidCallback onTap;
  final VoidCallback? onRevoke;

  const _ShareCard({
    required this.share,
    required this.isWithMe,
    required this.onTap,
    this.onRevoke,
  });

  @override
  State<_ShareCard> createState() => _ShareCardState();
}

class _ShareCardState extends State<_ShareCard> {
  Uint8List? _thumbnailBytes;
  bool _thumbLoading = false;

  @override
  void initState() {
    super.initState();
    if (!widget.share.isOneTime && !widget.share.isViewed) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    if (_thumbLoading) return;
    _thumbLoading = true;
    final bytes = await ShareService().fetchSharedImage(widget.share.id);
    if (mounted && bytes != null && bytes.isNotEmpty) {
      setState(() => _thumbnailBytes = bytes);
    }
    _thumbLoading = false;
  }

  @override
  Widget build(BuildContext context) {
    final isOneTime = widget.share.isOneTime;
    final isViewed = widget.share.isViewed;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // High contrast background
              Container(color: const Color(0xFF0A0A0A)),
              
              // Content
              if (isOneTime)
                _OneTimeContent(isViewed: isViewed)
              else
                Hero(
                  tag: 'share_${widget.share.id}',
                  child: _ThumbnailContent(bytes: _thumbnailBytes, loading: _thumbLoading),
                ),

              // Simple high-contrast bottom bar
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  color: Colors.black.withOpacity(0.8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (widget.isWithMe ? 'FROM ${widget.share.senderUsername ?? widget.share.senderId}' : 'TO ${widget.share.receiverId}').toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (isOneTime) ...[
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              isViewed ? Icons.visibility_off : Icons.bolt_sharp,
                              size: 8,
                              color: isViewed ? Colors.white24 : Colors.white,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              isViewed ? 'VIEWED' : 'ONE-TIME',
                              style: TextStyle(
                                color: isViewed ? Colors.white24 : Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.0,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Minimal Revoke Icon
              if (widget.onRevoke != null)
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: widget.onRevoke,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close_sharp, color: Colors.white, size: 12),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailContent extends StatelessWidget {
  final Uint8List? bytes;
  final bool loading;

  const _ThumbnailContent({this.bytes, this.loading = false});

  @override
  Widget build(BuildContext context) {
    if (bytes != null && bytes!.isNotEmpty) {
      return Image.memory(bytes!, fit: BoxFit.cover);
    }
    return Center(
      child: loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white24),
            )
          : const Icon(Icons.image_outlined, size: 28, color: Colors.white12),
    );
  }
}

class _OneTimeContent extends StatelessWidget {
  final bool isViewed;
  const _OneTimeContent({required this.isViewed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        isViewed ? Icons.visibility_off_outlined : Icons.bolt_outlined,
        size: 40,
        color: isViewed ? Colors.white10 : Colors.white,
      ),
    );
  }
}

class _RevokeSheet extends StatelessWidget {
  final VoidCallback onRevoke;
  final VoidCallback onCancel;

  const _RevokeSheet({required this.onRevoke, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'REVOKE SHARE?',
            style: TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: 3.0,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'THE RECIPIENT WILL NO LONGER BE ABLE TO ACCEESS THIS PHOTO. THIS ACTION IS INSTANT.',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 10,
              height: 2.0,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 60),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              GestureDetector(
                onTap: onCancel,
                child: const Text(
                  'CANCEL',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
              GestureDetector(
                onTap: onRevoke,
                child: const Text(
                  'REVOKE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 2.0,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
