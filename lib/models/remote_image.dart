class RemoteImage {
  final String imageId;
  final String userId;
  final String album;
  final int width;
  final int height;
  final int size;
  final double latitude;
  final double longitude;
  final String originalUrl;
  final String thumb256Url;
  final String thumb64Url;
  final String? sourceId; // Original asset ID from device
  final DateTime? createdAt;
  final bool isDeleted;
  bool isFavorite;

  RemoteImage({
    required this.imageId,
    required this.userId,
    this.album = '',
    required this.width,
    required this.height,
    this.size = 0,
    this.latitude = 0,
    this.longitude = 0,
    required this.originalUrl,
    required this.thumb256Url,
    required this.thumb64Url,
    this.sourceId,
    this.createdAt,
    this.isDeleted = false,
    this.isFavorite = false,
  });

  factory RemoteImage.fromJson(Map<String, dynamic> json) {
    return RemoteImage(
      imageId: json['image_id'] ?? '',
      userId: json['user_id'] ?? '',
      album: json['album'] ?? '',
      width: json['width'] ?? 0,
      height: json['height'] ?? 0,
      size: json['size'] ?? 0,
      latitude: (json['latitude'] ?? 0).toDouble(),
      longitude: (json['longitude'] ?? 0).toDouble(),
      originalUrl: json['original_url'] ?? '',
      thumb256Url: json['thumb_256_url'] ?? '',
      thumb64Url: json['thumb_64_url'] ?? '',
      sourceId: json['source_id'],
      createdAt: json['created_at'] != null 
          ? DateTime.tryParse(json['created_at']) 
          : null,
      isDeleted: json['is_deleted'] == true || json['is_deleted'] == 1,
      isFavorite: json['is_favorite'] == true || json['is_favorite'] == 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'image_id': imageId,
      'user_id': userId,
      'album': album,
      'width': width,
      'height': height,
      'size': size,
      'latitude': latitude,
      'longitude': longitude,
      'original_url': originalUrl,
      'thumb_256_url': thumb256Url,
      'thumb_64_url': thumb64Url,
      'source_id': sourceId,
      'created_at': createdAt?.toIso8601String(),
      'is_deleted': isDeleted,
      'is_favorite': isFavorite,
    };
  }
}

class RemoteImageResponse {
  final List<RemoteImage> images;
  final String? nextCursor;

  RemoteImageResponse({required this.images, this.nextCursor});

  factory RemoteImageResponse.fromJson(Map<String, dynamic> json) {
    final list = json['images'] as List? ?? [];
    final images = list.map((e) => RemoteImage.fromJson(e)).toList();
    return RemoteImageResponse(
      images: images,
      nextCursor: json['next_cursor'],
    );
  }
}
class RemoteSyncResponse {
  final List<RemoteImage> updates;
  final String? nextCursor;

  RemoteSyncResponse({required this.updates, this.nextCursor});

  factory RemoteSyncResponse.fromJson(Map<String, dynamic> json) {
    final list = json['updates'] as List? ?? [];
    final images = list.map((e) => RemoteImage.fromJson(e)).toList();
    return RemoteSyncResponse(
      updates: images,
      nextCursor: json['next_cursor'],
    );
  }
}
