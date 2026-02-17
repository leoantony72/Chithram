import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class FaceService {
  Future<void> initialize() async {
    print('FaceService: Web stub initialized.');
  }

  Future<List<dynamic>> detectFaces(File imageFile) async {
    return [];
  }

  Future<dynamic> getEmbeddingFromData(File originalImageFile, Rect faceRect, {Point<int>? leftEye, Point<int>? rightEye}) async {
    return null;
  }

  void dispose() {}
}

class FaceData {
  final List<double> embedding;
  final Uint8List thumbnail;
  FaceData(this.embedding, this.thumbnail);
}
