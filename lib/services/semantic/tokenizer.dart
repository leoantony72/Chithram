import 'dart:convert';
import 'package:flutter/services.dart';

class ClipTokenizer {
  static const int maxTokenLength = 77;
  static const int startTokenId = 49406;
  static const int endTokenId = 49407;
  static const int padTokenId = 0;

  Map<String, int> _encoder = {};
  Map<String, int> _bpeRanks = {};
  final Map<int, String> _bytesToUnicode = {};
  final Map<String, String> _cache = {};

  bool _initialized = false;
  bool get isInitialized => _initialized;

  Future<void> initialize() async {
    if (_initialized) return;

    // 1. Create bytes-to-unicode mapping
    final List<int> bs = [];
    for (int b = '!'.codeUnitAt(0); b <= '~'.codeUnitAt(0); b++) bs.add(b);
    for (int b = '¡'.codeUnitAt(0); b <= '¬'.codeUnitAt(0); b++) bs.add(b);
    for (int b = '®'.codeUnitAt(0); b <= 'ÿ'.codeUnitAt(0); b++) bs.add(b);

    final List<int> cs = List.from(bs);
    int n = 0;
    for (int b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    for (int i = 0; i < bs.length; i++) {
      _bytesToUnicode[bs[i]] = String.fromCharCode(cs[i]);
    }

    // 2. Load Vocab
    final vocabJson = await rootBundle.loadString('assets/models/semantic/clip_vocab.json');
    final Map<String, dynamic> vocabMap = jsonDecode(vocabJson);
    _encoder = vocabMap.map((key, value) => MapEntry(key, value as int));

    // 3. Load Merges/Ranks
    final mergesText = await rootBundle.loadString('assets/models/semantic/clip_merges.txt');
    final lines = mergesText.split('\n');
    int rank = 0;
    for (var line in lines) {
      if (line.trim().isEmpty) continue;
      _bpeRanks[line.trim()] = rank++;
    }

    _initialized = true;
  }

  String _bpe(String token) {
    if (_cache.containsKey(token)) return _cache[token]!;

    List<String> word = token.split('').toList();
    if (word.isEmpty) return '';
    word[word.length - 1] = '${word.last}</w>';

    Set<String> getPairs(List<String> word) {
      final Set<String> pairs = {};
      for (int i = 0; i < word.length - 1; i++) {
        pairs.add('${word[i]} ${word[i + 1]}');
      }
      return pairs;
    }

    Set<String> pairs = getPairs(word);
    if (pairs.isEmpty) return '${token}</w>';

    while (true) {
      String? bigram;
      int minRank = 999999999;

      for (var p in pairs) {
        final r = _bpeRanks[p];
        if (r != null && r < minRank) {
          minRank = r;
          bigram = p;
        }
      }

      if (bigram == null) break;

      final parts = bigram.split(' ');
      final first = parts[0];
      final second = parts[1];

      final List<String> newWord = [];
      int i = 0;
      while (i < word.length) {
        int nextIndex = word.indexOf(first, i);
        if (nextIndex == -1) {
          newWord.addAll(word.sublist(i));
          break;
        }
        newWord.addAll(word.sublist(i, nextIndex));
        i = nextIndex;

        if (word[i] == first && i < word.length - 1 && word[i + 1] == second) {
          newWord.add(first + second);
          i += 2;
        } else {
          newWord.add(word[i]);
          i += 1;
        }
      }
      word = newWord;
      if (word.length == 1) break;
      pairs = getPairs(word);
    }

    final result = word.join(' ');
    _cache[token] = result;
    return result;
  }

  List<int> tokenize(String text) {
    if (!_initialized) {
      // Fallback or throw? 
      // For safety return start + end tokens
      return [startTokenId, endTokenId] + List.filled(maxTokenLength - 2, padTokenId);
    }

    // Basic cleaning matching standard CLIP
    text = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    
    // Regexp for CLIP word splitting:
    // r"'''|\'s|\'t|\'re|\'ve|\'m|\'ll|\'d|[\p{L}]+|[\p{N}]+|[^\s\p{L}\p{N}]+"
    final pattern = RegExp(r"’s|’t|’re|’ve|’m|’ll|’d|[\p{L}]+|[\p{N}]+|[^\s\p{L}\p{N}]+", unicode: true);
    final matches = pattern.allMatches(text);
    
    final List<int> bpeTokens = [startTokenId];

    for (final match in matches) {
      final token = match.group(0)!;
      // Convert to byte-unicode string
      final bytes = utf8.encode(token);
      final word = bytes.map((b) => _bytesToUnicode[b]!).join('');
      
      final bpeRes = _bpe(word);
      for (final subword in bpeRes.split(' ')) {
        if (_encoder.containsKey(subword)) {
          bpeTokens.add(_encoder[subword]!);
        }
      }
    }

    bpeTokens.add(endTokenId);

    // Padding
    while (bpeTokens.length < maxTokenLength) {
      bpeTokens.add(padTokenId);
    }

    return bpeTokens.take(maxTokenLength).toList();
  }
}
