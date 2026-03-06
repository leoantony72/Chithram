import 'package:photo_manager/photo_manager.dart';
import 'remote_image.dart';

enum GalleryItemType { local, remote }

class GalleryItem {
  final GalleryItemType type;
  final AssetEntity? local;
  final RemoteImage? remote;

  final int version; // <--- Tracks manual refreshes/edits
  bool? _localFavoriteOverride;
  int? _localDurationOverride;
  
  GalleryItem.local(this.local, {bool? isFavorite, int? duration, this.version = 0}) 
    : type = GalleryItemType.local, 
      remote = null, 
      _localFavoriteOverride = isFavorite,
      _localDurationOverride = duration;

  GalleryItem.remote(this.remote, {this.version = 0}) : type = GalleryItemType.remote, local = null, _localFavoriteOverride = null, _localDurationOverride = null;

  GalleryItem copyWith({int? version, bool? isFavorite, int? duration}) {
     if (type == GalleryItemType.local) {
        return GalleryItem.local(
          local, 
          isFavorite: isFavorite ?? _localFavoriteOverride, 
          duration: duration ?? _localDurationOverride,
          version: version ?? this.version
        );
     } else {
        final newItem = GalleryItem.remote(remote, version: version ?? this.version);
        if (isFavorite != null) newItem.isFavorite = isFavorite;
        return newItem;
     }
  }

  String get id => type == GalleryItemType.local ? local!.id : remote!.imageId;
  
  DateTime get date {
    if (type == GalleryItemType.local) {
      return local!.createDateTime; 
    } else {
      return remote!.createdAt ?? DateTime.now();
    }
  }

  bool get isFavorite {
    if (type == GalleryItemType.local) {
      return _localFavoriteOverride ?? local!.isFavorite;
    }
    return remote?.isFavorite ?? false;
  }
  
  Duration get duration {
    if (type == GalleryItemType.local) {
      if (_localDurationOverride != null) return Duration(seconds: _localDurationOverride!);
      return local?.videoDuration ?? Duration.zero;
    }
    return Duration(seconds: remote?.duration ?? 0);
  }

  set isFavorite(bool value) {
    if (type == GalleryItemType.local) {
      _localFavoriteOverride = value;
    } else if (remote != null) {
      remote!.isFavorite = value;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GalleryItem && other.id == id && other.type == type;
  }

  @override
  int get hashCode => id.hashCode ^ type.hashCode;
}
