import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:go_router/go_router.dart';
import '../../providers/photo_provider.dart';
import '../../services/thumbnail_cache.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true, 
      appBar: AppBar(
        title: const Text('Albums'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.8),
                Colors.transparent,
              ],
            ),
          ),
        ),
      ),
      body: Consumer<PhotoProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading && provider.paths.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          
          return CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              // Locations Section
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(top: 100, bottom: 20),
                  child: Column(
                    children: [
                      const Text(
                        'LOCATIONS',
                        style: TextStyle(
                          color: Colors.grey,
                          letterSpacing: 2.0,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 200,
                        child: GestureDetector(
                          onTap: () {
                             context.push('/map');
                          },
                          child: Image.asset(
                            'assets/earth.png',
                            fit: BoxFit.contain,
                            errorBuilder: (context, error, stackTrace) {
                              return const Icon(Icons.public, size: 100, color: Colors.blueGrey);
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Planet Earth',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                       Text(
                        'Your Location',
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      const Text(
                        'My Albums',
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Text(
                        '${provider.paths.length} Albums',
                        style: TextStyle(color: Colors.grey[500], fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),

              // Albums Grid
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.85,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final path = provider.paths[index];
                      return AlbumCard(album: path);
                    },
                    childCount: provider.paths.length,
                  ),
                ),
              ),
              
              // Bottom padding
              const SliverToBoxAdapter(child: SizedBox(height: 50)),
            ],
          );
        },
      ),
    );
  }
}

// Simple in-memory cache to prevent async flicker on rebuilds
class AlbumMetadataCache {
  static final Map<String, int> counts = {}; 
  static final Map<String, AssetEntity> covers = {}; 
}

class AlbumCard extends StatefulWidget {
  final AssetPathEntity album;

  const AlbumCard({super.key, required this.album});

  @override
  State<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<AlbumCard> {
  AssetEntity? _coverAsset;
  Uint8List? _thumbBytes;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
    final String albumId = widget.album.id;

    // 1. Try Sync Load from Cache
    // This ensures that if we have visited this before, we render the image IMMEDIATELY (in the same frame),
    // preventing the "grey box" flicker.
    if (AlbumMetadataCache.counts.containsKey(albumId)) {
      _count = AlbumMetadataCache.counts[albumId]!;
    }
    
    if (AlbumMetadataCache.covers.containsKey(albumId)) {
      _coverAsset = AlbumMetadataCache.covers[albumId];
      if (_coverAsset != null) {
         final mem = ThumbnailCache().getMemory(_coverAsset!.id);
         if (mem != null) {
           _thumbBytes = mem;
         }
      }
    }

    // 2. Fetch fresh data if needed
    // If we missed cache, or just want to ensure consistency, we fetch.
    // If we hit cache, we only fetch if we suspect changes (optional), but for now 
    // to strictly fix the flicker, we only fetch if missing.
    if (_coverAsset == null || _count == 0) {
      _fetchData();
    }
  }

  Future<void> _fetchData() async {
    final String albumId = widget.album.id;
    
    // Parallel fetch for speed
    final countFuture = widget.album.assetCountAsync;
    final listFuture = widget.album.getAssetListRange(start: 0, end: 1);

    final results = await Future.wait([countFuture, listFuture]);
    final int newCount = results[0] as int;
    final List<AssetEntity> assets = results[1] as List<AssetEntity>;

    if (!mounted) return;

    AssetEntity? newCover;
    if (assets.isNotEmpty) {
      newCover = assets.first;
    }

    // Update Cache
    AlbumMetadataCache.counts[albumId] = newCount;
    if (newCover != null) {
      AlbumMetadataCache.covers[albumId] = newCover;
    }

    // Update State if changed
    if (newCount != _count || newCover?.id != _coverAsset?.id) {
      setState(() {
        _count = newCount;
        _coverAsset = newCover;
      });
      
      if (newCover != null) {
        _loadThumbnail(newCover);
      }
    } else if (_thumbBytes == null && newCover != null) {
       // Case: Cache had asset info but ThumbnailCache didn't have bytes yet (rare but possible)
       _loadThumbnail(newCover);
    }
  }

  Future<void> _loadThumbnail(AssetEntity asset) async {
    // Check memory first (again, just in case)
    final mem = ThumbnailCache().getMemory(asset.id);
    if (mem != null) {
      if (mounted) setState(() => _thumbBytes = mem);
      return;
    }
    // Load async
    final bytes = await ThumbnailCache().getThumbnail(asset);
    if (mounted && bytes != null) {
      setState(() => _thumbBytes = bytes);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        context.push('/album_details', extra: widget.album);
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
             BoxShadow(
               color: Colors.black.withOpacity(0.3),
               blurRadius: 8,
               offset: const Offset(0, 4),
             )
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Image
            if (_thumbBytes != null)
              Image.memory(_thumbBytes!, fit: BoxFit.cover, gaplessPlayback: true)
            else
              Container(
                color: Colors.grey[800],
                child: const Center(child: Icon(Icons.folder, color: Colors.white24, size: 48)),
              ),
            
            // Gradient Overlay
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 80,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.8),
                    ],
                  ),
                ),
              ),
            ),
            
            // Text
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.album.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$_count items',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontWeight: FontWeight.w400,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

