import 'package:flutter/material.dart';

class PeoplePage extends StatelessWidget {
  const PeoplePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('People'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: SearchBar(
              leading: const Icon(Icons.search),
              hintText: 'Search people...',
              onChanged: (value) {
                // Implement search logic here
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 10, // Mock count
              itemBuilder: (context, index) {
               // Mock grouping
                return ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person),
                  ),
                  title: Text('Person ${index + 1}'),
                  subtitle: Text('${(index + 1) * 5} Photos'),
                  onTap: () {
                    // Navigate to specific person's photos
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
