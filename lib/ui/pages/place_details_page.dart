import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../providers/photo_provider.dart';
import '../../services/travel_api_service.dart';
import '../widgets/thumbnail_widget.dart';
import '../widgets/remote_thumbnail_widget.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import '../../models/gallery_item.dart';

class PlaceDetailsPage extends StatefulWidget {
  final String city;
  const PlaceDetailsPage({super.key, required this.city});

  @override
  State<PlaceDetailsPage> createState() => _PlaceDetailsPageState();
}

class _PlaceDetailsPageState extends State<PlaceDetailsPage> {
  TravelInfo? _wikiSummary;
  List<NewsArticle> _news = [];
  List<AttractionImage> _attractions = [];
  WeatherInfo? _weather;
  bool _isLoadingData = true;
  latlong.LatLng? _cityLoc;

  @override
  void initState() {
    super.initState();
    // We will wait for build() to extract location from PhotoProvider
  }

  Future<void> _fetchLiveTravelData(latlong.LatLng? loc) async {
    final wiki = await TravelApiService().getDestinationSummary(widget.city);
    final news = await TravelApiService().getRecentAttractions(widget.city);
    final attractions = await TravelApiService().getAttractionImages(widget.city);
    
    WeatherInfo? weather;
    if (loc != null) {
       weather = await TravelApiService().getLiveWeather(loc.latitude, loc.longitude);
    }

    if (mounted) {
      setState(() {
        _wikiSummary = wiki;
        _news = news;
        _attractions = attractions;
        _weather = weather;
        _isLoadingData = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<PhotoProvider>(context);
    final photos = provider.placesVisited[widget.city] ?? [];
    
    if (photos.isEmpty) {
       return const Scaffold(backgroundColor: Colors.black, body: Center(child: Text("No memories found here.", style: TextStyle(color: Colors.white))));
    }
    
    if (_cityLoc == null) {
       for (var p in photos) {
         if (p.type == GalleryItemType.local && (p.local?.latitude ?? 0) != 0) {
            _cityLoc = latlong.LatLng(p.local!.latitude!, p.local!.longitude!);
            break;
         } else if (p.type == GalleryItemType.remote && p.remote!.latitude != 0) {
            _cityLoc = latlong.LatLng(p.remote!.latitude, p.remote!.longitude);
            break;
         }
       }
       // Fetch data now that loc is known
       if (_isLoadingData && _wikiSummary == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
             _fetchLiveTravelData(_cityLoc);
          });
       }
    }
    
    final coverPhoto = photos.first;

    // ----- TIME CAPSULE COMPUTATIONS -----
    final dates = photos.map((p) => p.date).toList();
    dates.sort();
    final oldest = dates.first;
    final newest = dates.last;
    final uniqueDays = photos.map((p) => DateTime(p.date.year, p.date.month, p.date.day)).toSet().length;
    final yearsDiff = newest.year - oldest.year;
    
    String timeSpanText = yearsDiff > 0 ? "$yearsDiff years apart" : "Single trip";

    // ----- ROUTE MAP POINTS -----
    final List<latlong.LatLng> routePoints = [];
    final List<CircleMarker> routeMarkers = [];
    
    final sortedByDate = List<GalleryItem>.from(photos)..sort((a, b) => a.date.compareTo(b.date));
    
    for (var p in sortedByDate) {
      double? lat, lng;
      if (p.type == GalleryItemType.local && (p.local?.latitude ?? 0) != 0) {
        lat = p.local!.latitude;
        lng = p.local!.longitude;
      } else if (p.type == GalleryItemType.remote && p.remote!.latitude != 0) {
        lat = p.remote!.latitude;
        lng = p.remote!.longitude;
      }
      
      if (lat != null && lng != null) {
        final pt = latlong.LatLng(lat, lng);
        routePoints.add(pt);
        routeMarkers.add(CircleMarker(
          point: pt,
          color: Colors.white,
          borderStrokeWidth: 1,
          borderColor: Colors.blueAccent,
          radius: 4,
        ));
      }
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 400.0,
            pinned: true,
            backgroundColor: const Color(0xFF0F172A),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.city, style: const TextStyle(fontWeight: FontWeight.bold, textBaseline: TextBaseline.alphabetic, letterSpacing: -1)),
              background: Stack(
                fit: StackFit.expand,
                children: [
                  Hero(
                    tag: 'cover_${widget.city}',
                    child: _buildCoverImage(coverPhoto),
                  ),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black54, Colors.transparent, Color(0xFF0F172A)],
                        stops: [0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 16,
                    right: 16,
                    child: SafeArea(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(Icons.edit, color: Colors.white, size: 20),
                          tooltip: 'Change Cover Photo',
                          onPressed: () => _showCoverPhotoSelector(context, photos, provider),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          SliverList(
            delegate: SliverChildListDelegate([
               const SizedBox(height: 20),
               
               // Wikipedia Summary Section
               if (_isLoadingData)
                 const Center(child: CircularProgressIndicator(color: Colors.white24))
               else if (_wikiSummary != null)
                 Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 24.0),
                   child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                         const Row(
                            children: [
                               Icon(Icons.info_outline, color: Colors.blueAccent, size: 20),
                               SizedBox(width: 8),
                               Text("About Destination", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, fontSize: 14)),
                            ],
                         ),
                         const SizedBox(height: 12),
                         Text(
                           _wikiSummary!.extract,
                           style: const TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                         ),
                      ],
                   )
                 ),
                 
               const SizedBox(height: 24),
               
               // TRIP STATS + TIME CAPSULE + WEATHER
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 24.0),
                 child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                       Expanded(
                         child: _buildStatCard(
                           icon: Icons.photo_library,
                           title: "Memories",
                           value: "${photos.length}",
                           subValue: "$uniqueDays days spent",
                         )
                       ),
                       const SizedBox(width: 12),
                       Expanded(
                         child: _buildStatCard(
                           icon: Icons.timelapse,
                           title: "Time Capsule",
                           value: DateFormat('yyyy').format(oldest),
                           subValue: timeSpanText,
                         )
                       ),
                       if (_weather != null) ...[
                         const SizedBox(width: 12),
                         Expanded(
                           child: _buildStatCard(
                             icon: null,
                             emojiIcon: _weather!.iconStr,
                             title: "Live Weather",
                             value: "${_weather!.temperature.round()}°C",
                             subValue: _weather!.condition,
                           )
                         ),
                       ]
                    ],
                 ),
               ),
               
               if (_cityLoc != null) ...[
                 const SizedBox(height: 24),
                 // MINI MAP PREVIEW
                 Container(
                    height: 140,
                    margin: const EdgeInsets.symmetric(horizontal: 24.0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                    ),
                    child: ClipRRect(
                       borderRadius: BorderRadius.circular(16),
                       child: IgnorePointer(
                         child: FlutterMap(
                           options: MapOptions(
                             initialCenter: _cityLoc!,
                             initialZoom: 12,
                           ),
                           children: [
                             TileLayer(
                               urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                               userAgentPackageName: 'com.example.ninta',
                             ),
                             if (routePoints.length > 1)
                               PolylineLayer(
                                 polylines: [
                                   Polyline(
                                     points: routePoints,
                                     color: Colors.blueAccent.withValues(alpha: 0.8),
                                     strokeWidth: 3.0,
                                   )
                                 ],
                               ),
                             CircleLayer(
                               circles: routeMarkers,
                             )
                           ],
                         ),
                       ),
                    ),
                 ),
               ],
                 
               const SizedBox(height: 40),
               
               // User Memories Horizontal Scroll
               Padding(
                 padding: const EdgeInsets.symmetric(horizontal: 24.0),
                 child: Row(
                    children: [
                       const Icon(Icons.photo_library, color: Colors.white, size: 20),
                       const SizedBox(width: 8),
                       Text("Your Memories (${photos.length})", style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                       const Spacer(),
                       TextButton(
                         onPressed: () {
                            context.push('/place_grid?city=${Uri.encodeComponent(widget.city)}');
                         },
                         child: const Text("See All >", style: TextStyle(color: Colors.blueAccent)),
                       )
                    ],
                 ),
               ),
               const SizedBox(height: 16),
               SizedBox(
                 height: 200,
                 child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: photos.length,
                    itemBuilder: (ctx, idx) {
                       final item = photos[idx];
                       return GestureDetector(
                         onLongPress: () async {
                            await provider.setJourneyCover(widget.city, item);
                            if (mounted) {
                               ScaffoldMessenger.of(context).showSnackBar(
                                 const SnackBar(
                                   content: Text("Journey cover updated!"),
                                   behavior: SnackBarBehavior.floating,
                                 )
                               );
                            }
                         },
                         child: Container(
                            width: 150,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            child: ClipRRect(
                               borderRadius: BorderRadius.circular(16),
                               child: item.type == GalleryItemType.local 
                                  ? ThumbnailWidget(entity: item.local!)
                                  : RemoteThumbnailWidget(image: item.remote!),
                            ),
                         ),
                       );
                    }
                 ),
               ),
               
               const SizedBox(height: 40),
               
               const SizedBox(height: 40),
               
               // WIKIPEDIA ATTRACTIONS SIGHTS
               if (!_isLoadingData && _attractions.isNotEmpty) ...[
                 Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 24.0),
                   child: Row(
                      children: [
                         const Icon(Icons.place, color: Colors.greenAccent, size: 20),
                         const SizedBox(width: 8),
                         const Text("Sights to See", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      ],
                   ),
                 ),
                 const SizedBox(height: 16),
                 SizedBox(
                   height: 160,
                   child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _attractions.length,
                      itemBuilder: (ctx, idx) {
                         final attr = _attractions[idx];
                         return GestureDetector(
                           onTap: () async {
                              final query = Uri.encodeComponent('${attr.title} ${widget.city}');
                              final mapUrl = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
                              try {
                                await launchUrl(mapUrl, mode: LaunchMode.platformDefault);
                              } catch (e) {
                                debugPrint("Could not launch map for ${attr.title}");
                              }
                           },
                           child: Container(
                              width: 160,
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              child: Stack(
                                 fit: StackFit.expand,
                                 children: [
                                    ClipRRect(
                                       borderRadius: BorderRadius.circular(16),
                                       child: Image.network(attr.imageUrl, fit: BoxFit.cover),
                                    ),
                                    Container(
                                       decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(16),
                                          gradient: const LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [Colors.black87, Colors.transparent],
                                          )
                                       ),
                                    ),
                                    Positioned(
                                       bottom: 12, left: 12, right: 12,
                                       child: Text(attr.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13), maxLines: 2, overflow: TextOverflow.ellipsis),
                                    )
                                 ],
                              ),
                           ),
                         );
                      }
                   ),
                 ),
                 const SizedBox(height: 40),
               ],
               
               // Google News Live RSS Section
               if (!_isLoadingData && _news.isNotEmpty) ...[
                 Padding(
                   padding: const EdgeInsets.symmetric(horizontal: 24.0),
                   child: Row(
                      children: [
                         const Icon(Icons.travel_explore, color: Colors.orangeAccent, size: 20),
                         const SizedBox(width: 8),
                         const Text("Recent Attractions & Updates", style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
                      ],
                   ),
                 ),
                 const SizedBox(height: 16),
                 ..._news.map((article) => _buildNewsCard(article)),
                 const SizedBox(height: 40),
               ]
            ]),
          )
        ],
      ),
    );
  }

  Widget _buildStatCard({IconData? icon, String? emojiIcon, required String title, required String value, required String subValue}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(16)
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (icon != null) Icon(icon, color: Colors.blueAccent, size: 16)
              else if (emojiIcon != null) Text(emojiIcon, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Expanded(child: Text(title, style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
            ]
          ),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: -0.5)),
          const SizedBox(height: 2),
          Text(subValue, style: const TextStyle(color: Colors.white30, fontSize: 10)),
        ],
      )
    );
  }

  void _showCoverPhotoSelector(BuildContext context, List<GalleryItem> photos, PhotoProvider provider) {
    GalleryItem? selectedPhoto;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              expand: false,
              builder: (ctx, scrollController) {
                return Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            "Set Journey Cover",
                            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                          ),
                          ElevatedButton(
                            onPressed: selectedPhoto == null ? null : () async {
                              await provider.setJourneyCover(widget.city, selectedPhoto!);
                              if (ctx.mounted) {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("Journey cover updated successfully!"),
                                    behavior: SnackBarBehavior.floating,
                                  )
                                );
                              }
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blueAccent,
                              disabledBackgroundColor: Colors.grey.withValues(alpha: 0.3),
                            ),
                            child: const Text("Save", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          )
                        ],
                      ),
                    ),
                    Expanded(
                      child: GridView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: photos.length,
                        itemBuilder: (ctx, idx) {
                          final item = photos[idx];
                          final isSelected = selectedPhoto == item;
                          return Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: isSelected ? Border.all(color: Colors.blueAccent, width: 4) : null,
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(isSelected ? 8 : 12),
                              child: item.type == GalleryItemType.local 
                                 ? ThumbnailWidget(
                                     entity: item.local!,
                                     onTap: () {
                                        setState(() {
                                          selectedPhoto = item;
                                        });
                                     },
                                   )
                                 : RemoteThumbnailWidget(
                                     image: item.remote!,
                                     onTap: () {
                                        setState(() {
                                          selectedPhoto = item;
                                        });
                                     },
                                   ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          }
        );
      },
    );
  }

  Widget _buildNewsCard(NewsArticle article) {
     return Container(
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        decoration: BoxDecoration(
           color: Colors.white.withValues(alpha: 0.05),
           borderRadius: BorderRadius.circular(16),
        ),
        child: ListTile(
           contentPadding: const EdgeInsets.all(16),
           title: Text(
              article.title, 
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
           ),
           subtitle: Padding(
             padding: const EdgeInsets.only(top: 8.0),
             child: Text("${article.source} • ${article.pubDate}", style: const TextStyle(color: Colors.white54, fontSize: 12)),
           ),
           trailing: const Icon(Icons.open_in_new, color: Colors.white30, size: 20),
           onTap: () async {
              final uri = Uri.parse(article.link);
              try {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              } catch (e) {
                debugPrint("Could not launch $uri");
              }
           },
        ),
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
