import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'dart:ui';
import '../../providers/photo_provider.dart';
import '../widgets/thumbnail_widget.dart';
import '../../models/gallery_item.dart';

class PlacesPage extends StatefulWidget {
  const PlacesPage({super.key});

  @override
  State<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends State<PlacesPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';
  bool _searchActive = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<PhotoProvider>(
      builder: (context, provider, child) {
        final places = provider.placesVisited;

        if (provider.isJourneyProcessing && places.isEmpty) {
          final progress = provider.journeyProgress;
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 250,
                  height: 6,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      backgroundColor: Colors.white12,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  "Processing Journeys... ${(progress * 100).toInt()}%",
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Organizing your photos by location",
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
          );
        }

        if (places.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.flight_takeoff, size: 64, color: Colors.white24),
                SizedBox(height: 16),
                Text("No Journeys Found", style: TextStyle(color: Colors.white54, fontSize: 18)),
                SizedBox(height: 8),
                Text("Tag locations onto your photos to see them here.", style: TextStyle(color: Colors.white30, fontSize: 14)),
              ],
            ),
          );
        }

        final allCityNames = places.keys.toList()
          ..sort((a, b) => (places[b]?.length ?? 0).compareTo(places[a]?.length ?? 0));
        final cityNames = _searchQuery.isEmpty
            ? allCityNames
            : allCityNames
                .where((c) => c.toLowerCase().contains(_searchQuery.toLowerCase()))
                .toList();

        // Calculate columns based on width
        final width = MediaQuery.of(context).size.width;
        int cols;
        if (width > 1200) cols = 5;
        else if (width > 900) cols = 4;
        else if (width > 600) cols = 3;
        else cols = 2;

        return Stack(
          children: [
            // Dark background gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF0F172A), Color(0xFF020617)],
                ),
              ),
            ),

            CustomScrollView(
              cacheExtent: 2000,
              slivers: [
                // ── Floating Header ──────────────────────────────────────────
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 60, 24, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                "Your Journeys",
                                style: TextStyle(
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: -0.5,
                                ),
                              ),
                            ),
                            // Search toggle
                            GestureDetector(
                              onTap: () {
                                setState(() {
                                  _searchActive = !_searchActive;
                                  if (!_searchActive) {
                                    _searchQuery = '';
                                    _searchController.clear();
                                  }
                                });
                              },
                              child: Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white12),
                                ),
                                child: Icon(
                                  _searchActive ? Icons.close : Icons.search_rounded,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Text(
                                '${allCityNames.length} Places',
                                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                        // ── Search Bar (animated) ──────────────────────────
                        AnimatedSize(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                          child: _searchActive
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 16),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(16),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.08),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: Colors.white12),
                                        ),
                                        child: Row(
                                          children: [
                                            const Icon(Icons.search_rounded, color: Colors.white38, size: 18),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: TextField(
                                                controller: _searchController,
                                                autofocus: true,
                                                style: const TextStyle(color: Colors.white, fontSize: 16),
                                                decoration: const InputDecoration(
                                                  hintText: 'Search journeys...',
                                                  hintStyle: TextStyle(color: Colors.white30),
                                                  border: InputBorder.none,
                                                  isDense: true,
                                                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                                                ),
                                                onChanged: (v) => setState(() => _searchQuery = v),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
                ),

                // ── Empty search result ───────────────────────────────────────
                if (cityNames.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.search_off_rounded, size: 48, color: Colors.white24),
                          const SizedBox(height: 12),
                          Text(
                            'No journey matching "$_searchQuery"',
                            style: const TextStyle(color: Colors.white38, fontSize: 15),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 80),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final city = cityNames[index];
                          final photos = places[city]!;
                          final coverPhoto = photos.first;
                          return _JourneyCard(
                            city: city,
                            photos: photos,
                            coverPhoto: coverPhoto,
                          );
                        },
                        childCount: cityNames.length,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: cols,
                        childAspectRatio: 0.72,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Isolated stateless card to keep grid rendering fast.
class _JourneyCard extends StatefulWidget {
  final String city;
  final List<GalleryItem> photos;
  final GalleryItem coverPhoto;

  const _JourneyCard({
    required this.city,
    required this.photos,
    required this.coverPhoto,
  });

  @override
  State<_JourneyCard> createState() => _JourneyCardState();
}

class _JourneyCardState extends State<_JourneyCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return GestureDetector(
      onTap: () => context.push('/place_details?city=${Uri.encodeComponent(widget.city)}'),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 14,
                offset: const Offset(0, 6),
              )
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cover photo
                Hero(
                  tag: 'cover_${widget.city}',
                  child: ThumbnailWidget(
                    key: ValueKey('highres_${widget.city}'),
                    item: widget.coverPhoto,
                    isHighRes: true,
                  ),
                ),
                // Gradient overlay
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black87],
                      stops: [0.45, 1.0],
                    ),
                  ),
                ),
                // Text info
                Positioned(
                  bottom: 14,
                  left: 12,
                  right: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.city,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(Icons.photo_library_outlined, color: Colors.white54, size: 12),
                          const SizedBox(width: 4),
                          Text(
                            '${widget.photos.length}',
                            style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

