import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

class AlbumSelectionResult {
  final AssetPathEntity? localAlbum;
  final String? cloudAlbumName;

  AlbumSelectionResult({this.localAlbum, this.cloudAlbumName});
}

class AlbumPickerDialog extends StatefulWidget {
  final List<AssetPathEntity> localAlbums;
  final List<String> existingCloudAlbums; // Optional feature

  const AlbumPickerDialog({
    super.key,
    required this.localAlbums,
    this.existingCloudAlbums = const [],
  });

  @override
  State<AlbumPickerDialog> createState() => _AlbumPickerDialogState();
}

class _AlbumPickerDialogState extends State<AlbumPickerDialog> {
  final TextEditingController _customAlbumController = TextEditingController();
  bool _isCreatingCustom = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Add to Album', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isCreatingCustom) ...[
              ListTile(
                leading: const Icon(Icons.add_circle_outline, color: Colors.blueAccent),
                title: const Text('Create New Cloud Album', style: TextStyle(color: Colors.white)),
                onTap: () {
                  setState(() => _isCreatingCustom = true);
                },
              ),
              const Divider(color: Colors.white12),
              
              if (widget.existingCloudAlbums.isNotEmpty) ...[
                 Padding(
                   padding: const EdgeInsets.only(top: 8.0, bottom: 4.0, left: 16.0),
                   child: Text("CLOUD ALBUMS", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
                 ),
                 ...widget.existingCloudAlbums.map((name) => ListTile(
                    leading: const Icon(Icons.cloud_done, color: Colors.white54),
                    title: Text(name, style: const TextStyle(color: Colors.white70)),
                    onTap: () => Navigator.pop(context, AlbumSelectionResult(cloudAlbumName: name)),
                 )),
                 const Divider(color: Colors.white12),
              ],

              Padding(
                padding: const EdgeInsets.only(top: 8.0, bottom: 4.0, left: 16.0),
                child: Text("DEVICE FOLDERS", style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.localAlbums.length,
                  itemBuilder: (context, index) {
                    final album = widget.localAlbums[index];
                    return ListTile(
                      leading: const Icon(Icons.folder_shared, color: Colors.white70),
                      title: Text(album.name, style: const TextStyle(color: Colors.white)),
                      subtitle: FutureBuilder<int>(
                        future: album.assetCountAsync,
                        builder: (context, snapshot) {
                          if (snapshot.hasData) {
                             return Text('${snapshot.data} items', style: TextStyle(color: Colors.white54, fontSize: 12));
                          }
                          return const SizedBox();
                        },
                      ),
                      onTap: () {
                        Navigator.pop(context, AlbumSelectionResult(localAlbum: album));
                      },
                    );
                  },
                ),
              ),
            ] else ...[
              const Text('Enter a name for the new cloud album:', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              TextField(
                controller: _customAlbumController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Album Name',
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (val) {
                  if (val.trim().isNotEmpty) {
                    Navigator.pop(context, AlbumSelectionResult(cloudAlbumName: val.trim()));
                  }
                },
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => setState(() => _isCreatingCustom = false),
                    child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                       final val = _customAlbumController.text.trim();
                       if (val.isNotEmpty) {
                          Navigator.pop(context, AlbumSelectionResult(cloudAlbumName: val));
                       }
                    },
                    style: ElevatedButton.styleFrom(
                       backgroundColor: Colors.blueAccent,
                       foregroundColor: Colors.white
                    ),
                    child: const Text('Create'),
                  )
                ],
              )
            ]
          ],
        ),
      ),
    );
  }
}
