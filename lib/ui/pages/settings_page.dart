import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/backup_service.dart';
import '../../services/federated_learning_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final BackupService _backupService = BackupService();
  bool _isLoading = true;
  List<AssetPathEntity> _allAlbums = [];
  
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      // 1. Init Backup Service (loads settings)
      await _backupService.init();
      
      // 2. Load Albums
      final permission = await PhotoManager.requestPermissionExtend();
      if (permission.isAuth) {
        _allAlbums = await PhotoManager.getAssetPathList(type: RequestType.common);
      }
    } catch (e) {
      debugPrint("Error loading settings data: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _isLoading 
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (!kIsWeb && !Platform.isWindows) _buildBackupSection(),
                if (!kIsWeb && !Platform.isWindows) const Divider(),
                if (!kIsWeb) _buildFLSection(),
                if (kIsWeb) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text("Web Interface Settings (Local Features Disabled)"))),
              ],
            ),
    );
  }

  Widget _buildFLSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text('Federated Learning', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        ),
        ListTile(
          title: const Text('Sync Model'),
          subtitle: const Text('Download latest global model and enhance local detection'),
          trailing: IconButton(
            icon: const Icon(Icons.sync),
            onPressed: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Syncing learning models...")),
              );
              await FederatedLearningService().init(); // Download global
              await FederatedLearningService().trainAndUpload(); // Train local
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Model sync completed!")),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildBackupSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: const Text('Enable Backup'),
          subtitle: const Text('Encrypt and upload photos to secure cloud'),
          value: _backupService.isBackupEnabled,
          onChanged: (val) async {
            await _backupService.toggleBackup(val);
            setState(() {});
          },
        ),
        if (_backupService.isBackupEnabled) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text('Select Albums to Backup', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (_allAlbums.isEmpty)
             const Padding(padding: EdgeInsets.all(16), child: Text('No albums found.')),
          
          for (var album in _allAlbums)
            CheckboxListTile(
              title: FutureBuilder<int>(
                future: album.assetCountAsync, 
                builder: (c, snapshot) => Text('${album.name} (${snapshot.data ?? 0})'),
              ),
              value: _backupService.selectedAlbumIds.contains(album.id),
              onChanged: (checked) async {
                 final current = List<String>.from(_backupService.selectedAlbumIds);
                 if (checked == true) {
                    if (!current.contains(album.id)) current.add(album.id);
                 } else {
                    current.remove(album.id);
                 }
                 await _backupService.setSelectedAlbums(current);
                 setState(() {});
              },
            ),
        ],
      ],
    );
  }
}
