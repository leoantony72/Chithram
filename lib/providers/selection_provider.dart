import 'package:flutter/material.dart';
import '../models/gallery_item.dart';

class SelectionProvider with ChangeNotifier {
  final Set<GalleryItem> _selectedItems = {};
  bool _isSelectionMode = false;

  bool get isSelectionMode => _isSelectionMode;
  Set<GalleryItem> get selectedItems => _selectedItems;

  bool isSelected(GalleryItem item) => _selectedItems.contains(item);

  void toggleSelection(GalleryItem item) {
    if (_selectedItems.contains(item)) {
      _selectedItems.remove(item);
    } else {
      _selectedItems.add(item);
    }
    
    if (_selectedItems.isEmpty) {
      _isSelectionMode = false;
    } else {
      _isSelectionMode = true;
    }
    notifyListeners();
  }

  void selectAll(List<GalleryItem> items) {
    _selectedItems.addAll(items);
    _isSelectionMode = true;
    notifyListeners();
  }

  void clearSelection() {
    _selectedItems.clear();
    _isSelectionMode = false;
    notifyListeners();
  }
}
