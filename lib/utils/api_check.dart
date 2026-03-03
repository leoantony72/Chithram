import 'package:photo_manager/photo_manager.dart';

void main() async {
  final asset = AssetEntity(id: 'test', typeInt: 0, width: 0, height: 0);
  try {
    print('Testing android refresh...');
    // In Some versions it was refreshAssetProperties
    await PhotoManager.editor.android.refreshAssetProperties(asset);
  } catch (e) {
    print('Error: $e');
  }
}
