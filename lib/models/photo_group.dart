import 'gallery_item.dart';

class PhotoGroup {
  final DateTime date;
  final List<GalleryItem> items;

  PhotoGroup({required this.date, required this.items});
}

enum GroupMode {
  day,
  month,
  year
}
