import 'dart:math';
import 'package:flutter/foundation.dart';
import 'database_service.dart';

class ClusterService {
  final DatabaseService _dbService = DatabaseService();
  
  // Threshold for Euclidean distance. 
  // MobileFaceNet typically uses 1.0 - 1.2 for verification.
  // Adjust based on testing.
  // DBSCAN Epsilon (Max distance between two faces to be considered neighbors)
  // Since we normalize vectors (L2), range is 0.0 to 2.0.
  // 0.0 = Identical.
  // 1.0 = Orthogonal.
  // 0.7 - 0.8 is usually a high confidence match (Cosine Similarity ~ 0.7)
  // 1.0 - 1.2 is the standard MobileFaceNet threshold boundary (Cosine Sim ~ 0.3 - 0.5)
  // For highly scattered lighting and clothing changes, 1.15 drastically merges identities.
  static const double _eps = 1.15; 
  static const int _minPoints = 1; // Even a single face is a person

  Future<void> runClustering() async {
    print('Starting Global Clustering...');
    final db = await _dbService.database;
    
    // 1. Clear existing clusters and assignments
    // (In a real app, we might want to preserve named clusters, but here we rebuild)
    print('Clearing DB clusters...');
    await db.delete('clusters');
    await db.update('faces', {'cluster_id': null});

    // 2. Fetch all valid embeddings
    print('Fetching faces...');
    final faces = await _dbService.getAllFaces();
    print('Fetched ${faces.length} faces. Parsing blobs...');
    final List<_FaceNode> nodes = [];
    
    for (var f in faces) {
       final blob = f['embedding'] as Uint8List?;
       if (blob != null) {
          final vec = _loadEmbedding(blob);
          if (vec.isNotEmpty) {
             nodes.add(_FaceNode(f['id'], vec));
          }
       }
    }

    if (nodes.isEmpty) {
        print('No valid face embeddings found to cluster.');
        return;
    }
    print('Clustering ${nodes.length} valid faces...');

    // 3. DBSCAN Algorithm
    int clusterCount = 0;
    
    try {
      for (var i = 0; i < nodes.length; i++) {
        // Yield to prevent UI freeze
        if (i % 5 == 0) await Future.delayed(Duration.zero);

        if (nodes[i].visited) continue;
        
        nodes[i].visited = true;
        final neighbors = _regionQuery(nodes, nodes[i]); // Get neighbors
        
        // Mark these initial neighbors as "known" to prevent duplicates in the list
        final Set<int> knownNeighborIds = neighbors.map((n) => n.id).toSet();
        knownNeighborIds.add(nodes[i].id);

        if (neighbors.length < _minPoints) {
           // Treated as noise or single-person cluster
        }
        
        // Expand Cluster
        clusterCount++;
        final clusterName = 'Person $clusterCount';
        
        final clusterId = await _dbService.createCluster(
          name: clusterName,
          representativeFaceId: nodes[i].id, 
        );

        final List<_FaceNode> clusterMembers = [nodes[i]];
        
        // Expand using list iteration
        for (var k = 0; k < neighbors.length; k++) {
           final neighbor = neighbors[k];
           
           if (!neighbor.visited) {
              neighbor.visited = true;
              final neighborNeighbors = _regionQuery(nodes, neighbor);
              
              if (neighborNeighbors.length >= _minPoints) {
                 for (var nn in neighborNeighbors) {
                    if (!knownNeighborIds.contains(nn.id)) {
                       neighbors.add(nn);
                       knownNeighborIds.add(nn.id);
                    }
                 }
              }
           }
           
           if (!neighbor.clustered) {
              clusterMembers.add(neighbor);
              neighbor.clustered = true;
           }
        }
        nodes[i].clustered = true; 

        // 4. Save Cluster Members
        for (var member in clusterMembers) {
           await _dbService.updateFaceCluster(member.id, clusterId);
        }
        
        // 5. Update Centroid
        await _calculateAndSaveCentroid(clusterId, clusterMembers);
      }
    } catch (e, stack) {
      print('Clustering Error: $e');
      print(stack);
    }
    
    print('Clustering Complete. Found $clusterCount clusters.');
  }

  List<_FaceNode> _regionQuery(List<_FaceNode> allNodes, _FaceNode center) {
    final List<_FaceNode> neighbors = [];
    for (var node in allNodes) {
       if (node.id == center.id) continue;
       final dist = _calculateEuclideanDistance(center.embedding, node.embedding);
       if (dist <= _eps) {
          neighbors.add(node);
       }
    }
    return neighbors;
  }

  Future<void> _calculateAndSaveCentroid(int clusterId, List<_FaceNode> members) async {
    if (members.isEmpty) return;
    
    // Calculate Mean Vector
    final int dim = members[0].embedding.length;
    final meanVector = List<double>.filled(dim, 0.0);
    
    for (var m in members) {
       for (var i = 0; i < dim; i++) meanVector[i] += m.embedding[i];
    }
    
    // Normalize
    double magnitude = 0;
    for (var i = 0; i < dim; i++) {
       meanVector[i] /= members.length;
       magnitude += meanVector[i] * meanVector[i];
    }
    magnitude = sqrt(magnitude);
    if (magnitude > 0) {
       for (var i = 0; i < dim; i++) meanVector[i] /= magnitude;
    }

    final bytes = Float32List.fromList(meanVector).buffer.asUint8List();
    await _dbService.updateClusterEmbedding(clusterId, bytes);
  }

  List<double> _loadEmbedding(Uint8List blob) {
    if (blob.lengthInBytes % 4 != 0) {
      print('ClusterService: Skipping invalid blob of size ${blob.lengthInBytes}');
      return [];
    }
    
    var buffer = blob.buffer;
    var offset = blob.offsetInBytes;
    
    // Fix alignment issues (offset 237 etc)
    if (offset % 4 != 0) {
        final copy = Uint8List.fromList(blob);
        buffer = copy.buffer;
        offset = 0;
    }
    
    try {
      return Float32List.view(buffer, offset, blob.lengthInBytes ~/ 4).toList();
    } catch (e) {
      print('ClusterService: Error parsing blob: $e');
      return [];
    }
  }

  double _calculateEuclideanDistance(List<double> v1, List<double> v2) {
    double sum = 0;
    for (int i = 0; i < v1.length; i++) {
      final diff = v1[i] - v2[i];
      sum += diff * diff;
    }
    return sqrt(sum);
  }
}

class _FaceNode {
  final int id;
  final List<double> embedding;
  bool visited = false;
  bool clustered = false;
  
  _FaceNode(this.id, this.embedding);
}
