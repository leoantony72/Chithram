import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:collection/collection.dart';
import '../../services/database_service.dart';
import '../widgets/section_header_delegate.dart';
import 'photo_viewer_page.dart'; // Ensure this exists or use placeholder

class PersonDetailsPage extends StatefulWidget {
  final String personName;
  final int personId;

  const PersonDetailsPage({
    super.key,
    required this.personName,
    required this.personId,
  });

  @override
  State<PersonDetailsPage> createState() => _PersonDetailsPageState();
}

class _PersonDetailsPageState extends State<PersonDetailsPage> {
  final DatabaseService _dbService = DatabaseService();
  List<_FileGroup> _groupedFiles = [];
  bool _isLoading = true;
  late String _currentName;

  @override
  void initState() {
    super.initState();
    _currentName = widget.personName;
    _loadPersonAssets();
  }

  Future<void> _loadPersonAssets() async {
    final paths = await _dbService.getPhotoPathsForCluster(widget.personId);
    
    final List<File> files = [];
    for (final p in paths) {
      final f = File(p);
      if (await f.exists()) {
        files.add(f);
      }
    }

    // Group by Date
    // We async fetch LastModified.
    final Map<DateTime, List<File>> groups = {};
    
    for (final f in files) {
      DateTime date;
      try {
        date = await f.lastModified();
      } catch (_) {
        date = DateTime.now();
      }
      final key = DateTime(date.year, date.month, date.day);
      if (!groups.containsKey(key)) groups[key] = [];
      groups[key]!.add(f);
    }

    final List<_FileGroup> sorted = groups.entries.map((e) => _FileGroup(e.key, e.value)).toList();
    sorted.sort((a, b) => b.date.compareTo(a.date));

    if (mounted) {
      setState(() {
        _groupedFiles = sorted;
        _isLoading = false;
      });
    }
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _currentName);
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Person'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter Name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                 await _dbService.updateClusterName(widget.personId, controller.text);
                 setState(() => _currentName = controller.text);
                 Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return DateFormat('EEE, d MMM yyyy').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentName),
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: _editName),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groupedFiles.isEmpty
              ? const Center(child: Text('No photos found.'))
              : CustomScrollView(
                  slivers: [
                    for (var group in _groupedFiles) ...[
                      SliverPersistentHeader(
                        delegate: SectionHeaderDelegate(title: _formatDate(group.date)),
                      ),
                      SliverGrid(
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final file = group.files[index];
                            return GestureDetector(
                              onTap: () {
                                // Navigate to viewer (simplified)
                                // We could implement a proper viewer but standard Image.file is okay for MVP
                                Navigator.push(context, MaterialPageRoute(builder: (_) => _SimplePhotoViewer(file: file)));
                              },
                              child: Image.file(file, fit: BoxFit.cover, cacheWidth: 300),
                            );
                          },
                          childCount: group.files.length,
                        ),
                      ),
                    ]
                  ],
                ),
    );
  }
}

class _FileGroup {
  final DateTime date;
  final List<File> files;
  _FileGroup(this.date, this.files);
}

class _SimplePhotoViewer extends StatelessWidget {
  final File file;
  const _SimplePhotoViewer({required this.file});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
      backgroundColor: Colors.black,
      body: Center(child: Image.file(file)),
    );
  }
}
