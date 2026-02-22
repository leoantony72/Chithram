class RemoteImage {
  final String imageId;
  final String userId;
  final String album;
  final int width;
  final int height;
  final String originalUrl;
  final String thumb256Url;
  final String thumb64Url;
  final String? sourceId; // Original asset ID from device
  final DateTime? createdAt;

  RemoteImage({
    required this.imageId,
    required this.userId,
    this.album = '',
    required this.width,
    required this.height,
    required this.originalUrl,
    required this.thumb256Url,
    required this.thumb64Url,
    this.sourceId,
    this.createdAt,
  });

  factory RemoteImage.fromJson(Map<String, dynamic> json) {
    return RemoteImage(
      imageId: json['image_id'] ?? '',
      userId: json['user_id'] ?? '',
      album: json['album'] ?? '',
      width: json['width'] ?? 0,
      height: json['height'] ?? 0,
      originalUrl: json['original_url'] ?? '',
      thumb256Url: json['thumb_256_url'] ?? '',
      thumb64Url: json['thumb_64_url'] ?? '',
      sourceId: json['source_id'],
      createdAt: json['created_at'] != null 
          ? DateTime.tryParse(json['created_at']) 
          : null,
    );
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
