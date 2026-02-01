import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_heatmap/flutter_map_heatmap.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/photo_provider.dart';
import '../widgets/thumbnail_widget.dart';
import 'dart:ui';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager_image_provider/photo_manager_image_provider.dart';

class MapPage extends StatefulWidget {
  const MapPage({super.key});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  // Map State
  final MapController _mapController = MapController();
  double _currentZoom = 2.0;
  bool _isDarkMap = true; // Default to dark google style
  
  // Data State -- Derived from Provider
  List<AssetEntity> _geoAssets = [];
  List<AssetEntity> _visibleAssets = [];
  
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _initMapData();
  }

  Future<void> _initMapData() async {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
       if (!mounted) return;
       final provider = Provider.of<PhotoProvider>(context, listen: false);
       
       // Ensure scanning is running
       if (!provider.isLocationScanning) {
          provider.startLocationScan();
       }
       
       // Initial update
       _updateGeoAssetsFromProvider();
    });
  }

  void _updateGeoAssetsFromProvider() {
    final provider = Provider.of<PhotoProvider>(context, listen: false);
    final all = provider.allAssets;
    final cache = provider.locationCache;
    
    // Filter assets that have a location (either in cache or native)
    final List<AssetEntity> withLoc = [];
    
    for (final asset in all) {
      if (cache.containsKey(asset.id)) {
        withLoc.add(asset);
      } else if ((asset.latitude ?? 0) != 0 && (asset.longitude ?? 0) != 0) {
        // We technically should add this to cache for consistency, but provider handles that background scan
        // For UI purposes, we can use it.
        withLoc.add(asset);
      }
    }
    
    setState(() {
      _geoAssets = withLoc;
    });
    
    // Auto-center on the "mass" of photos if we have data AND havn't moved map yet (optional check)
    if (withLoc.isNotEmpty && _currentZoom == 2.0) {
      final center = _calculateCentroid(withLoc, cache);
      if (center != null) {
         WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _mapController.move(center, 10.0);
         });
      }
    }
    
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateVisibleAssets());
  }

  latlong.LatLng? _calculateCentroid(List<AssetEntity> assets, Map<String, latlong.LatLng> cache) {
    if (assets.isEmpty) return null;
    double sumLat = 0;
    double sumLng = 0;
    int count = 0;
    
    for (var asset in assets) {
      // Prefer cache, fallback to native
      latlong.LatLng? pos = cache[asset.id];
      if (pos == null && (asset.latitude ?? 0) != 0) {
         pos = latlong.LatLng(asset.latitude!, asset.longitude!);
      }
      
      if (pos != null) {
          sumLat += pos.latitude;
          sumLng += pos.longitude;
          count++;
      }
    }
    
    if (count == 0) return null;
    return latlong.LatLng(sumLat / count, sumLng / count);
  }

  void _onMapPositionChanged(MapPosition position, bool hasGesture) {
     if (hasGesture) {
       _debounceTimer?.cancel();
       _debounceTimer = Timer(const Duration(milliseconds: 300), () {
          _updateVisibleAssets();
       });
     }
     if (position.zoom != null && position.zoom != _currentZoom) {
        setState(() {
          _currentZoom = position.zoom!;
        });
     }
  }

  void _updateVisibleAssets() {
     if (!mounted) return;
     final provider = Provider.of<PhotoProvider>(context, listen: false);
     final cache = provider.locationCache;
     
     // Retrieve visible bounds
     final bounds = _mapController.camera.visibleBounds;
     
     // Filter _geoAssets that are inside bounds
     final visible = _geoAssets.where((asset) {
        latlong.LatLng? pos = cache[asset.id];
        if (pos == null && (asset.latitude ?? 0) != 0) {
             pos = latlong.LatLng(asset.latitude!, asset.longitude!);
        }
        if (pos == null) return false;
        return bounds.contains(pos);
     }).toList();

     setState(() {
        _visibleAssets = visible;
     });
  }

  @override
  Widget build(BuildContext context) {
    // Listen to provider updates (for scan progress and new locations)
    final provider = Provider.of<PhotoProvider>(context);
    
    // Calculate date range string
    String dateRangeText = "";
    if (_geoAssets.isNotEmpty) {
      final dates = _geoAssets.map((e) => e.createDateTime).whereType<DateTime>().toList();
      if (dates.isNotEmpty) {
        dates.sort();
        final start = dates.first;
        final end = dates.last;
        dateRangeText = "${start.year} - ${end.month == DateTime.now().month && end.year == DateTime.now().year ? 'Now' : end.year}";     
      }
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const latlong.LatLng(0, 0), 
              initialZoom: _currentZoom,
              minZoom: 2.0,
              maxZoom: 18.0,
              backgroundColor: _isDarkMap ? const Color(0xFF161B21) : const Color(0xFFE0E0E0),
              interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all & ~InteractiveFlag.rotate, 
              ),
              onPositionChanged: _onMapPositionChanged,
              onMapReady: () {
                  _updateVisibleAssets();
              },
            ),
            children: [
              // Dark Mode / Light Mode Tiles
              TileLayer(
                urlTemplate: _isDarkMap 
                    ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}@2x.png'
                    : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}@2x.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.ninta', 
              ),
              
              // Heatmap Layer
              if (_currentZoom < 14 && _geoAssets.isNotEmpty)
                HeatMapLayer(
                  heatMapDataSource: InMemoryHeatMapDataSource(
                    data: _geoAssets.map((e) {
                        final pos = provider.locationCache[e.id] ?? latlong.LatLng(e.latitude ?? 0, e.longitude ?? 0);
                        return WeightedLatLng(pos, 1);
                    }).toList(),
                  ),
                  heatMapOptions: HeatMapOptions(
                    gradient: <double, MaterialColor>{
                      0.10: Colors.deepPurple,
                      0.30: Colors.indigo,
                      0.50: Colors.blue,
                      0.70: Colors.cyan,
                      0.85: Colors.green, // Dominant green
                      1.0: Colors.lime    // Ends in Lime (yellow-green) for very subtle yellow tint
                    },
                    radius: 35, // Very tight radius for detailed clusters
                    minOpacity: 0.05, 
                    blurFactor: 0.9, // Maximum blur for gaseous look
                  ),
                ),
                
              // Markers Layer (DOTS ONLY - NO PHOTOS)
              if (_currentZoom >= 14 && _geoAssets.isNotEmpty)
                MarkerLayer(
                  markers: _geoAssets.map((asset) {
                    final pos = provider.locationCache[asset.id] ?? latlong.LatLng(asset.latitude ?? 0, asset.longitude ?? 0);
                    return Marker(
                      point: pos,
                      width: 12, 
                      height: 12,
                      child: GestureDetector(
                         onTap: () => context.push('/viewer', extra: asset),
                         child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFF4285F4),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                              boxShadow: [
                                 BoxShadow(color: Colors.black.withOpacity(0.3), blurRadius: 4)
                              ]
                            ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
            ],
          ),
          
          // Floating Top Bar
          Positioned(
            top: MediaQuery.paddingOf(context).top + 10,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                
                Row(
                  children: [
                    // Theme Toggle
                    Container(
                      margin: const EdgeInsets.only(right: 12),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: Icon(_isDarkMap ? Icons.wb_sunny : Icons.nightlight_round, color: Colors.white, size: 20),
                        onPressed: () { 
                           setState(() {
                             _isDarkMap = !_isDarkMap;
                           });
                        },
                      ),
                    ),

                    if (provider.isLocationScanning)
                      Container(
                        margin: const EdgeInsets.only(right: 12),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.4),
                          borderRadius: BorderRadius.circular(20)
                        ),
                        child: Text(
                          "${(provider.locationScanProgress*100).toInt()}%", 
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)
                        ),
                      ),
                      
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.4),
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        onPressed: () { 
                           _updateGeoAssetsFromProvider();
                           if (!provider.isLocationScanning) provider.startLocationScan();
                        },
                      ),
                    ),
                  ],
                )
              ],
            ),
          ),
          
          // Recenter FAB
          Positioned(
             right: 16,
             bottom: MediaQuery.of(context).size.height * 0.22,
             child: FloatingActionButton.small(
               backgroundColor: const Color(0xFF303030),
               foregroundColor: const Color(0xFFE3E3E3),
               shape: const CircleBorder(),
               onPressed: () {
                  final center = _calculateCentroid(_geoAssets, provider.locationCache);
                  if (center != null) _mapController.move(center, 10.0);
               },
               child: const Icon(Icons.my_location),
             ),
          ),
          
          // Bottom Sheet
          DraggableScrollableSheet(
            initialChildSize: 0.15, 
            minChildSize: 0.12,
            maxChildSize: 0.85,
            builder: (context, scrollController) {
              return Container(
                decoration: BoxDecoration(
                  color: _isDarkMap ? const Color(0xFF1F1F1F) : Colors.white,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, -2))]
                ),
                child: CustomScrollView(
                  controller: scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // Header Section (Draggable)
                    SliverToBoxAdapter(
                        child: Column(
                          children: [
                            Center(
                              child: Container(
                                margin: const EdgeInsets.only(top: 12, bottom: 4),
                                width: 32, 
                                height: 4,
                                decoration: BoxDecoration(
                                  color: (_isDarkMap ? Colors.white : Colors.black).withOpacity(0.2), 
                                  borderRadius: BorderRadius.circular(2)
                                ),
                              ),
                            ),
                            
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                      _visibleAssets.isEmpty ? "No photos in view" : "${_visibleAssets.length} photos", 
                                      style: TextStyle(
                                        color: _isDarkMap ? Colors.white : Colors.black87, 
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500
                                      )
                                  ),
                                  if (dateRangeText.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2.0),
                                      child: Text(
                                        dateRangeText, 
                                        style: TextStyle(
                                          color: (_isDarkMap ? Colors.white : Colors.black).withOpacity(0.6), 
                                          fontSize: 12
                                        )
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ),
                    
                    // Grid Content
                    _visibleAssets.isEmpty 
                    ? const SliverFillRemaining(child: SizedBox())
                    : SliverGrid(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                          childAspectRatio: 1.0,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final asset = _visibleAssets[index];
                            return InkWell(
                              onTap: () => context.push('/viewer', extra: asset),
                              child: Hero(
                                tag: 'map_grid_${asset.id}',
                                child: Image(
                                  image: AssetEntityImageProvider(
                                    asset,
                                    isOriginal: false,
                                    thumbnailSize: const ThumbnailSize.square(200),
                                  ),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            );
                          },
                          childCount: _visibleAssets.length,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}