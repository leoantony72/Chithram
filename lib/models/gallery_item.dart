import 'package:photo_manager/photo_manager.dart';
import 'remote_image.dart';

enum GalleryItemType { local, remote }

class GalleryItem {
  final GalleryItemType type;
  final AssetEntity? local;
  final RemoteImage? remote;

  GalleryItem.local(this.local) : type = GalleryItemType.local, remote = null;
  GalleryItem.remote(this.remote) : type = GalleryItemType.remote, local = null;

  String get id => type == GalleryItemType.local ? local!.id : remote!.imageId;
  
  DateTime get date {
    if (type == GalleryItemType.local) {
      return local!.createDateTime; 
    } else {
      return remote!.createdAt ?? DateTime.now();
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
