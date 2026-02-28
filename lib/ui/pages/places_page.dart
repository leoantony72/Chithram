import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/photo_provider.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/remote_thumbnail_widget.dart';
import '../../models/gallery_item.dart';

class PlacesPage extends StatefulWidget {
  const PlacesPage({super.key});

  @override
  State<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends State<PlacesPage> {
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    // Configure viewport fraction to allow peeking at next cards
    _pageController = PageController(viewportFraction: 0.85);
  }

  @override
  void dispose() {
    _pageController.dispose();
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
            )
          );
        }

        final cityNames = places.keys.toList()..sort();

        return Stack(
          children: [
            // Dark Background gradient
            Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF0F172A), Color(0xFF020617)], // Modern Slate Slate
                ),
              ),
            ),
            
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 60, 24, 20),
                  child: Row(
                    children: [
                      const Text(
                        "Your Journeys",
                        style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: -0.5),
                      ),
                      const Spacer(),
                      Chip(
                        label: Text('${cityNames.length} Places', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        side: BorderSide.none,
                      )
                    ],
                  ),
                ),
                
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final isDesktop = constraints.maxWidth > 800;

                      if (isDesktop) {
                        return GridView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: constraints.maxWidth > 1200 ? 5 : constraints.maxWidth > 1000 ? 4 : 3,
                            childAspectRatio: 0.75,
                            crossAxisSpacing: 24,
                            mainAxisSpacing: 24,
                          ),
                          itemCount: cityNames.length,
                          itemBuilder: (context, index) {
                            final city = cityNames[index];
                            final photos = places[city]!;
                            final coverPhoto = photos.first;

                            return GestureDetector(
                              onTap: () {
                                context.push('/place_details?city=${Uri.encodeComponent(city)}');
                              },
                              child: MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: const [
                                      BoxShadow(color: Colors.black45, blurRadius: 15, offset: Offset(0, 8))
                                    ]
                                  ),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(24),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Hero(
                                          tag: 'cover_$city',
                                          child: _buildCoverImage(coverPhoto),
                                        ),
                                        // Gradient Overlay
                                        Container(
                                          decoration: const BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [Colors.transparent, Colors.black87],
                                              stops: [0.5, 1.0],
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: 20,
                                          left: 16,
                                          right: 16,
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                city,
                                                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: -0.5),
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              const SizedBox(height: 4),
                                              Row(
                                                children: [
                                                  const Icon(Icons.photo_library, color: Colors.white70, size: 14),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    '${photos.length} Memories',
                                                    style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
                                                  ),
                                                ],
                                              )
                                            ],
                                          ),
                                        )
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      }

                      // Mobile PageView Default
                      return PageView.builder(
                        controller: _pageController,
                        itemCount: cityNames.length,
                        itemBuilder: (context, index) {
                          final city = cityNames[index];
                          final photos = places[city]!;
                          final coverPhoto = photos.first;

                          return AnimatedBuilder(
                            animation: _pageController,
                            builder: (context, child) {
                              double value = 1.0;
                              if (_pageController.position.haveDimensions) {
                                value = _pageController.page! - index;
                                value = (1 - (value.abs() * 0.2)).clamp(0.0, 1.0);
                              }
                              
                              return Center(
                                child: SizedBox(
                                  height: Curves.easeOut.transform(value) * MediaQuery.of(context).size.height * 0.65,
                                  width: Curves.easeOut.transform(value) * MediaQuery.of(context).size.width,
                                  child: child,
                                ),
                              );
                            },
                            child: GestureDetector(
                              onTap: () {
                                 context.push('/place_details?city=${Uri.encodeComponent(city)}');
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(30),
                                  boxShadow: const [
                                    BoxShadow(color: Colors.black54, blurRadius: 20, offset: Offset(0, 10))
                                  ]
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(30),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      Hero(
                                        tag: 'cover_$city',
                                        child: _buildCoverImage(coverPhoto),
                                      ),
                                      // Gradient Overlay
                                      Container(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                            colors: [Colors.transparent, Colors.black87],
                                            stops: [0.5, 1.0],
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        bottom: 30,
                                        left: 24,
                                        right: 24,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              city,
                                              style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.bold, letterSpacing: -1),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                const Icon(Icons.photo_library, color: Colors.white70, size: 16),
                                                const SizedBox(width: 6),
                                                Text(
                                                  '${photos.length} Memories',
                                                  style: const TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.w500),
                                                ),
                                              ],
                                            )
                                          ],
                                        ),
                                      )
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 40),
              ],
            )
          ],
        );
      },
    );
  }

  Widget _buildCoverImage(GalleryItem item) {
    if (item.type == GalleryItemType.local) {
      return ThumbnailWidget(entity: item.local!, isHighRes: true);
    } else {
      return RemoteThumbnailWidget(image: item.remote!, isHighRes: true);
    }
  }
}
