import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../services/backup_service.dart';
import '../../services/federated_learning_service.dart';
import '../../services/api_config.dart';
import '../../providers/photo_provider.dart';
import '../../models/gallery_item.dart';
import '../../services/database_service.dart';

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
      await _backupService.init();
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        final permission = await PhotoManager.requestPermissionExtend();
        if (permission.isAuth) {
          _allAlbums = await PhotoManager.getAssetPathList(type: RequestType.common);
        }
      }
    } catch (e) {
      debugPrint("Error loading settings data: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            pinned: true,
            flexibleSpace: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Container(color: Colors.black.withOpacity(0.5)),
              ),
            ),
            title: const Text(
              'Settings',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.5),
            ),
          ),
          if (_isLoading)
             const SliverFillRemaining(child: Center(child: CircularProgressIndicator(color: Colors.white)))
          else
             SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    _buildNetworkSection(),
                    const SizedBox(height: 24),
                    _buildSemanticSection(),
                    const SizedBox(height: 24),
                    if (!kIsWeb && !Platform.isWindows) _buildBackupSection(),
                    if (!kIsWeb && !Platform.isWindows) const SizedBox(height: 24),
                    if (!kIsWeb) _buildFLSection(),
                    if (kIsWeb) 
                      const Center(child: Text("Web Interface Settings (Local Features Disabled)", style: TextStyle(color: Colors.white54))),
                    const SizedBox(height: 100), // padding for scroll
                  ]),
                ),
             ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.blueAccent, size: 20),
          const SizedBox(width: 8),
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 12,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGlassCard({required Widget child}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _buildNetworkSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Connection', Icons.wifi_rounded),
        _buildGlassCard(
          child: FutureBuilder<String>(
            future: ApiConfig().getCurrentIp(),
            builder: (context, snapshot) {
              final currentIp = snapshot.data ?? 'Loading...';
              return _CustomListTile(
                title: 'Backend API Host',
                subtitle: currentIp,
                icon: Icons.dns_rounded,
                onTap: () {
                  final controller = TextEditingController(text: currentIp);
                  _showCustomDialog(
                    title: 'Set Custom IP',
                    content: TextField(
                      controller: controller,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'e.g. 192.168.1.5',
                        hintStyle: const TextStyle(color: Colors.white30),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    onSave: () async {
                      if (controller.text.isNotEmpty) {
                        await ApiConfig().setCustomIp(controller.text);
                        if (mounted) setState(() {});
                        Navigator.pop(context);
                      }
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSemanticSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('Semantic Search', Icons.manage_search_rounded),
        _buildGlassCard(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Consumer<PhotoProvider>(
              builder: (context, provider, child) {
                final int totalItems = provider.allItems.where((i) => i.type == GalleryItemType.local || i.type == GalleryItemType.remote).length;
                final int indexedCount = provider.semanticIndexedCount;
                final bool isIndexing = provider.isSemanticIndexing;
                final double progress = provider.semanticProgress;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: Colors.purpleAccent.withOpacity(0.2), shape: BoxShape.circle),
                          child: const Icon(Icons.smart_toy_rounded, color: Colors.purpleAccent, size: 24),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('AI Indexing Progress', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 4),
                              Text(
                                isIndexing 
                                  ? 'Processing your library for smart semantic search...' 
                                  : 'Indexing paused or fully complete.',
                                style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.3),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isIndexing ? '${(progress * 100).toStringAsFixed(1)}%' : 'Indexed',
                          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '$indexedCount / $totalItems photos',
                          style: const TextStyle(color: Colors.white54, fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Custom Modern Progress Bar
                    Container(
                      height: 8,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: totalItems > 0 
                            ? (isIndexing ? progress : (indexedCount / totalItems).clamp(0.0, 1.0))
                            : 0.0,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Colors.blueAccent, Colors.purpleAccent],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            borderRadius: BorderRadius.circular(4),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.purpleAccent.withOpacity(0.4),
                                blurRadius: 8,
                                offset: const Offset(0, 2),
                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (!isIndexing && indexedCount < totalItems)
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.1),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                           provider.startSemanticIndexing();
                        },
                        icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        label: const Text('Resume Indexing'),
                      ),
                    const SizedBox(height: 12),
                    // Clear & Re-index — wipes corrupted embeddings and forces fresh indexing
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent, width: 1),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: isIndexing ? null : () async {
                        // Confirm before wiping
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            backgroundColor: const Color(0xFF1C1C1E),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                            title: const Text('Clear AI Index?', style: TextStyle(color: Colors.white)),
                            content: const Text(
                              'This will delete all saved semantic embeddings and re-index your entire library from scratch. This cannot be undone.',
                              style: TextStyle(color: Colors.white54, height: 1.5),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Clear & Re-index', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                        );
                        if (confirm != true) return;
                        await DatabaseService().clearSemanticEmbeddings();
                        if (context.mounted) {
                          await provider.initSemanticStats();
                          provider.startSemanticIndexing();
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('AI index cleared. Re-indexing started...')),
                          );
                        }
                      },
                      icon: const Icon(Icons.refresh_rounded, size: 18),
                      label: const Text('Clear & Re-index'),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFLSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader('AI & Models', Icons.psychology_rounded),
        _buildGlassCard(
          child: _CustomListTile(
            title: 'Federated Learning Sync',
            subtitle: 'Download latest global model and enhance local detection privately.',
            icon: Icons.sync_rounded,
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Syncing learning models...")));
              await FederatedLearningService().init();
              await FederatedLearningService().trainAndUpload();
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Model sync completed!")));
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
        _buildSectionHeader('Cloud Backup', Icons.cloud_upload_rounded),
        _buildGlassCard(
          child: Column(
            children: [
              _CustomSwitchTile(
                title: 'Enable E2E Encrypted Backup',
                subtitle: 'Securely upload your photos using military-grade encryption.',
                icon: Icons.lock_outline_rounded,
                value: _backupService.isBackupEnabled,
                onChanged: (val) async {
                  await _backupService.toggleBackup(val);
                  setState(() {});
                },
              ),
              if (_backupService.isBackupEnabled) ...[
                Divider(color: Colors.white.withOpacity(0.1), height: 1),
                if (_allAlbums.isEmpty)
                   const Padding(padding: EdgeInsets.all(24), child: Text('No albums found locally.', style: TextStyle(color: Colors.white54))),
                for (var album in _allAlbums)
                  _CustomCheckboxTile(
                    album: album,
                    isSelected: _backupService.selectedAlbumIds.contains(album.id),
                    onChanged: (checked) async {
                       final current = List<String>.from(_backupService.selectedAlbumIds);
                       if (checked) {
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
          ),
        ),
      ],
    );
  }

  void _showCustomDialog({required String title, required Widget content, required VoidCallback onSave}) {
    showGeneralDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      barrierDismissible: true,
      barrierLabel: "Dialog",
      pageBuilder: (ctx, anim1, anim2) => Center(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.grey[900]?.withOpacity(0.8),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  content,
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel', style: TextStyle(color: Colors.white54)),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: onSave,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Custom UI Components

class _CustomListTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _CustomListTile({required this.title, required this.subtitle, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      splashColor: Colors.white.withOpacity(0.1),
      highlightColor: Colors.white.withOpacity(0.05),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.2), shape: BoxShape.circle),
              child: Icon(icon, color: Colors.blueAccent, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.3)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}

class _CustomSwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CustomSwitchTile({required this.title, required this.subtitle, required this.icon, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
           Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: (value ? Colors.blueAccent : Colors.white54).withOpacity(0.2), shape: BoxShape.circle),
              child: Icon(icon, color: value ? Colors.blueAccent : Colors.white54, size: 24),
            ),
            const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => onChanged(!value),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              width: 52,
              height: 30,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: value ? Colors.blueAccent : Colors.white.withOpacity(0.1),
                border: Border.all(color: value ? Colors.blueAccent : Colors.white.withOpacity(0.2)),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomCheckboxTile extends StatelessWidget {
  final AssetPathEntity album;
  final bool isSelected;
  final ValueChanged<bool> onChanged;

  const _CustomCheckboxTile({required this.album, required this.isSelected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!isSelected),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: FutureBuilder<int>(
                future: album.assetCountAsync, 
                builder: (c, snapshot) => Text(
                  '${album.name}  •  ${snapshot.data ?? 0} items',
                  style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 15, fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400),
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isSelected ? Colors.blueAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: isSelected ? Colors.blueAccent : Colors.white30, width: 2),
              ),
              child: isSelected ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
            )
          ],
        ),
      ),
    );
  }
}
