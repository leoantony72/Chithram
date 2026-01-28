import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:photo_manager/photo_manager.dart';
import '../../providers/photo_provider.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Albums')),
      body: Consumer<PhotoProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
           if (provider.paths.isEmpty) {
            return const Center(child: Text('No albums found.'));
          }
          
          return ListView.builder(
            itemCount: provider.paths.length,
            itemBuilder: (context, index) {
              final AssetPathEntity path = provider.paths[index];
              return ListTile(
                leading: const Icon(Icons.folder),
                title: Text(path.name),
                subtitle: FutureBuilder<int>(
                  future: path.assetCountAsync,
                  builder: (context, snapshot) {
                     if (snapshot.hasData) {
                       return Text('${snapshot.data} items');
                     }
                     return const Text('Loading...');
                  },
                ),
                 onTap: () {
                    // Navigate to album details
                 },
              );
            },
          );
        },
      ),
    );
  }
}
