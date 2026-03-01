import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import '../../providers/selection_provider.dart';
import '../../services/backup_service.dart';
import '../../services/auth_service.dart';
import '../../models/remote_image.dart';
import '../../models/gallery_item.dart';
import '../widgets/thumbnail_widget.dart';

class CloudAlbumDetailsPage extends StatefulWidget {
  final String albumName;

  const CloudAlbumDetailsPage({super.key, required this.albumName});

  @override
  State<CloudAlbumDetailsPage> createState() => _CloudAlbumDetailsPageState();
}

class _CloudAlbumDetailsPageState extends State<CloudAlbumDetailsPage> {
  final List<RemoteImage> _images = [];
  bool _isLoading = true;
  String? _cursor;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchImages();

    _scrollController.addListener(() {
      if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
        if (!_isLoading && _hasMore) {
          _fetchImages();
        }
      }
    });
  }

  Future<void> _fetchImages() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final session = await AuthService().loadSession();
      if (session != null) {
        final userId = session['username'] as String;
        final response = await BackupService().fetchRemoteImages(
            userId,
            cursor: _cursor,
            album: widget.albumName
        );

        if (response != null) {
          setState(() {
            _images.addAll(response.images);
            _cursor = response.nextCursor;
            _hasMore = response.nextCursor != null && response.nextCursor!.isNotEmpty;
          });
        }
      }
    } catch (e) {
      debugPrint("Error fetching album images: $e");
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(60),
        child: Consumer<SelectionProvider>(
          builder: (context, selection, child) {
            if (selection.isSelectionMode) {
              return AppBar(
                backgroundColor: Colors.black,
                elevation: 0,
                leading: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => selection.clearSelection(),
                ),
                title: Text('${selection.selectedItems.length} selected', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.library_add_outlined, color: Colors.white),
                    tooltip: 'Add to album',
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_location_alt_outlined, color: Colors.white),
                    tooltip: 'Add location',
                    onPressed: () {},
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    tooltip: 'Delete',
                    onPressed: () {},
                  ),
                  const SizedBox(width: 8),
                ],
              );
            }
            return AppBar(
              backgroundColor: Colors.black,
              elevation: 0,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => context.pop(),
              ),
              title: Text(widget.albumName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            );
          },
        ),
      ),
      body: _images.isEmpty && _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.white70))
          : _images.isEmpty
              ? const Center(child: Text("No photos found in this album", style: TextStyle(color: Colors.white54)))
              : GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                  gridDelegate: kIsWeb
                      ? const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 6,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        )
                      : const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 220,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                  itemCount: _images.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _images.length) {
                      return const Center(child: CircularProgressIndicator(color: Colors.white70));
                    }
                    final item = GalleryItem.remote(_images[index]);
                    return ThumbnailWidget(
                      item: item,
                      onTap: () {
                         context.push('/viewer', extra: {
                            'item': item,
                            'items': _images.map((e) => GalleryItem.remote(e)).toList(),
                         });
                      },
                    );
                  },
                ),
    );
  }
}
