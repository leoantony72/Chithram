import 'package:photo_manager/photo_manager.dart';

class PhotoGroup {
  final DateTime date;
  final List<AssetEntity> assets;

  PhotoGroup({required this.date, required this.assets});
}

enum GroupMode {
  day,
  month,
  year
}
