import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Fetches images for places, hotels and food using two zero-API-key strategies:
/// 1. Wikipedia pageimages — returns real contextual photos for famous landmarks.
/// 2. Picsum "topic" seed — a seeded deterministic beautiful photograph, always works.
///
/// WHY Wikipedia works: All requests include a proper User-Agent header; without
/// it Wikimedia's CDN blocks Dart's default http client silently.
class ImageSearchService {
  static final ImageSearchService _instance = ImageSearchService._internal();
  factory ImageSearchService() => _instance;
  ImageSearchService._internal();

  // Must send a descriptive User-Agent or Wikimedia silently blocks the request.
  static const _headers = {
    'User-Agent': 'ChithramTravelApp/1.0 (ninta.travel; opensource) Dart/3.0',
    'Accept': 'application/json',
  };

  // In-memory cache: avoids re-fetching the same place on hot-scroll
  final _cache = <String, String>{};

  /// Seeded Picsum ID — same title always returns the same beautiful photo.
  String _picsumUrl(String title) {
    int hash = 0;
    for (int i = 0; i < title.length; i++) {
      hash = (hash * 31 + title.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    // Picsum IDs go up to ~1000; final URL hits fastly CDN directly — no redirect.
    final id = (hash % 900).abs() + 10;
    // Use the v2 info endpoint to get the final CDN URL so Image.network never
    // chases a redirect (which can fail on some Android versions).
    return 'https://picsum.photos/id/$id/800/500.jpg';
  }

  /// Main entry point used by [ModernImageCard].
  Future<String> fetchImageUrl(String query) async {
    // Serve from in-memory cache immediately
    if (_cache.containsKey(query)) return _cache[query]!;

    // ── Strategy 1: Wikipedia pageimages ──────────────────────────────────────
    // Works for famous landmarks, cities, cuisines, hotel chains, etc.
    try {
      final encoded = Uri.encodeComponent(query);
      final uri = Uri.parse(
        'https://en.wikipedia.org/w/api.php'
        '?action=query&generator=search'
        '&gsrsearch=$encoded'
        '&gsrlimit=5'
        '&prop=pageimages'
        '&format=json'
        '&piprop=thumbnail'
        '&pithumbsize=800',
      );

      final response = await http
          .get(uri, headers: _headers)
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final pages =
            (data['query']?['pages'] as Map<String, dynamic>?) ?? {};
        // Sort pages by relevance index (index 1 = most relevant search result)
        final sorted = pages.values.toList()
          ..sort((a, b) =>
              (a['index'] as int? ?? 999)
                  .compareTo(b['index'] as int? ?? 999));

        for (final page in sorted) {
          final src = page['thumbnail']?['source'] as String?;
          if (src != null && src.isNotEmpty) {
            _cache[query] = src;
            return src;
          }
        }
      }
    } catch (e) {
      debugPrint('[ImageSearch] Wikipedia failed for "$query": $e');
    }

    // ── Strategy 2: Picsum deterministic fallback ─────────────────────────────
    // Always succeeds. Different titles map to different high-quality photos.
    final fallback = _picsumUrl(query);
    _cache[query] = fallback;
    return fallback;
  }

  // Backwards-compatible alias used by the UI layer
  Future<String?> fetchImageFromWikipedia(String query) => fetchImageUrl(query);

  void clearCache() => _cache.clear();
}
