import 'dart:math';
import 'package:flutter/foundation.dart';
import 'database_service.dart';

class ClusterService {
  final DatabaseService _dbService = DatabaseService();
  
  // Threshold for Euclidean distance. 
  // MobileFaceNet typically uses 1.0 - 1.2 for verification.
  // Adjust based on testing.
  static const double _similarityThreshold = 1.0; 

  Future<void> processFace(int faceId, List<double> newEmbedding) async {
    final clusters = await _dbService.getAllClusters();
    
    int? bestClusterId;
    double minDistance = double.infinity;

    for (var cluster in clusters) {
      final representativeFaceId = cluster['representative_face_id'] as int;
      // Fetch representative face embedding
      // Ideally cache this or fetch in batch
      final faces = await _dbService.getAllFaces(); 
      final repFace = faces.firstWhere((f) => f['id'] == representativeFaceId);
      final repEmbedding = _loadEmbedding(repFace['embedding']);

      final distance = _calculateEuclideanDistance(newEmbedding, repEmbedding);
      
      if (distance < _similarityThreshold && distance < minDistance) {
        minDistance = distance;
        bestClusterId = cluster['id'];
      }
    }

    if (bestClusterId != null) {
      // Add to existing cluster
      await _dbService.updateFaceCluster(faceId, bestClusterId);
      print('Face $faceId added to Cluster $bestClusterId (Dist: $minDistance)');
    } else {
      // Create new cluster
      final newClusterId = await _dbService.createCluster(
        name: 'Person ${clusters.length + 1}',
        representativeFaceId: faceId,
      );
      await _dbService.updateFaceCluster(faceId, newClusterId);
      print('Created new Cluster $newClusterId for Face $faceId');
    }
  }

  List<double> _loadEmbedding(Uint8List blob) {
    // Assuming purely float32 bytes for now, or just handle list conversion
    return Float32List.view(blob.buffer).toList();
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
