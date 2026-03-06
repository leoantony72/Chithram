import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:ui';
import '../../services/trip_planner_service.dart';
import '../../services/image_search_service.dart';

class TripPlannerPage extends StatefulWidget {
  final String city;
  final String timeCapsuleInfo;
  final String memoryCountInfo;
  final List<String> placesVisited;

  const TripPlannerPage({
    super.key,
    required this.city,
    required this.timeCapsuleInfo,
    required this.memoryCountInfo,
    required this.placesVisited,
  });

  @override
  State<TripPlannerPage> createState() => _TripPlannerPageState();
}

class _TripPlannerPageState extends State<TripPlannerPage> {
  final _plannerService = TripPlannerService();
  final _apiKeyController = TextEditingController();
  String _currentSection = '';

  bool _isLoading = false;
  String? _errorMessage;
  String? _tripPlan;
  bool _needsApiKey = false;
  bool _isCachedPlan = false; // true when loaded from local cache
  DateTime? _cachedDate;       // when the cached plan was generated

  @override
  void initState() {
    super.initState();
    _checkApiKeyAndGenerate();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _checkApiKeyAndGenerate() async {
    // ── 1. Try the local cache first (instant load, no API call) ──
    final cached = await _plannerService.getCachedPlan(widget.city);
    if (cached != null && cached.isNotEmpty) {
      final date = await _plannerService.getCachedPlanDate(widget.city);
      if (mounted) {
        setState(() {
          _tripPlan = cached;
          _isCachedPlan = true;
          _cachedDate = date;
        });
      }
      return;
    }

    // ── 2. No cache → check API key then generate ──
    final key = await _plannerService.getApiKey();
    if (key == null || key.isEmpty) {
      if (mounted) setState(() => _needsApiKey = true);
    } else {
      _generatePlan();
    }
  }

  Future<void> _saveKeyAndProceed() async {
    final key = _apiKeyController.text.trim();
    if (key.isEmpty) return;
    await _plannerService.saveApiKey(key);
    if (mounted) {
      setState(() => _needsApiKey = false);
      _generatePlan();
    }
  }

  Future<void> _generatePlan() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isCachedPlan = false;
    });
    // Clear old image cache so cards fetch fresh images for the new plan
    ImageSearchService().clearCache();

    try {
      final plan = await _plannerService.generateTripPlan(
        city: widget.city,
        timeCapsuleInfo: widget.timeCapsuleInfo,
        memoryCountInfo: widget.memoryCountInfo,
        placesVisited: widget.placesVisited,
      );
      if (mounted) {
        setState(() {
          _tripPlan = plan;
          _isLoading = false;
          _cachedDate = DateTime.now();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
          if (e.toString().contains('invalid') || e.toString().contains('expired')) {
            _needsApiKey = true;
            _plannerService.clearApiKey();
          }
        });
      }
    }
  }

  /// Force-regenerate a fresh plan (clears local cache first).
  Future<void> _regenerate() async {
    await _plannerService.clearCachedPlan(widget.city);
    _generatePlan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text("Trip Planner: ${widget.city}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        actions: [
          if (_tripPlan != null) ...[
            // Show cached date chip
            if (_isCachedPlan && _cachedDate != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: GestureDetector(
                  onTap: _regenerate,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.refresh_rounded, size: 13, color: Colors.blueAccent),
                        const SizedBox(width: 5),
                        Text(
                          '${_cachedDate!.day}/${_cachedDate!.month}',
                          style: const TextStyle(color: Colors.blueAccent, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            IconButton(
              icon: const Icon(Icons.copy_outlined, size: 20),
              tooltip: 'Copy Itinerary',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _tripPlan!));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Itinerary copied!')));
                }
              },
            ),
          ],
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_needsApiKey) return _buildApiKeyPrompt();
    if (_isLoading) return _buildLoading();
    if (_errorMessage != null) return _buildError();
    if (_tripPlan != null) return _buildPlan();
    return const SizedBox.shrink();
  }

  Widget _buildApiKeyPrompt() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
             const Icon(Icons.psychology, size: 80, color: Colors.blueAccent),
             const SizedBox(height: 24),
             const Text(
               "AI Trip Planner",
               style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
             ),
             const SizedBox(height: 16),
             const Text(
               "To curate a beautifully tailored itinerary, Chithram uses Google's Gemini AI. Since Chithram is fully open-source and respects your privacy, you'll need to provide your own free Gemini API Key. It will be stored securely on your device.",
               style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
               textAlign: TextAlign.center,
             ),
             const SizedBox(height: 24),
             TextField(
                controller: _apiKeyController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                   labelText: "Gemini API Key",
                   labelStyle: const TextStyle(color: Colors.white54),
                   filled: true,
                   fillColor: Colors.white.withValues(alpha: 0.1),
                   border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                   prefixIcon: const Icon(Icons.key, color: Colors.blueAccent),
                ),
             ),
             const SizedBox(height: 16),
             Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                   TextButton(
                      onPressed: () async {
                         final uri = Uri.parse("https://aistudio.google.com/app/apikey");
                         if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                         }
                      },
                      child: const Text("Get a free key", style: TextStyle(color: Colors.blueAccent)),
                   ),
                   const SizedBox(width: 16),
                   ElevatedButton(
                      onPressed: _saveKeyAndProceed,
                      style: ElevatedButton.styleFrom(
                         backgroundColor: Colors.blueAccent,
                         padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                         shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text("Save & Generate", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                   ),
                ],
             )
          ],
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
           const CircularProgressIndicator(color: Colors.blueAccent),
           const SizedBox(height: 24),
           Text(
             "Curating the perfect itinerary for ${widget.city}...",
             style: const TextStyle(color: Colors.white70, fontSize: 16),
           ),
        ],
      )
    );
  }

  Widget _buildError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
             const Icon(Icons.error_outline, color: Colors.redAccent, size: 60),
             const SizedBox(height: 16),
             Text(
               _errorMessage ?? "An unknown error occurred.",
               style: const TextStyle(color: Colors.white, fontSize: 16),
               textAlign: TextAlign.center,
             ),
             const SizedBox(height: 24),
             if (!_needsApiKey) // If it didn't already force an API key reset
               ElevatedButton(
                  onPressed: _generatePlan,
                  child: const Text("Try Again"),
               ),
          ],
        ),
      ),
    );
  }

  List<TripSection> _parsePlan(String markdown) {
    List<TripSection> sections = [];
    
    // Fallback if the AI didn't use ## for the first section
    TripSection currentSection = TripSection("Trip Overview", []);
    
    final lines = markdown.split('\n');
    for (String line in lines) {
      if (line.trim().isEmpty) continue;
      
      if (line.startsWith('## ')) {
        // Start of a new structured section
        currentSection = TripSection(line.substring(3).trim(), []);
        sections.add(currentSection);
      } else if (line.startsWith('# ')) {
        // Usually the AI output title, we can just skip or add as title
        continue;
      } else {
        bool isCardItem = false;
        
        // Attempt to parse list items into Image Cards
        if (line.trim().startsWith('- ')) {
           int colonIndex = line.indexOf(':');
           if (colonIndex != -1 && colonIndex < 60) {
              String entryPart = line.substring(line.indexOf('- ') + 2, colonIndex);
              String title = entryPart.replaceAll('**', '').replaceAll('*', '').trim();
              String desc = line.substring(colonIndex + 1).replaceAll('**', '').replaceAll('*', '').trim();
              
              // Only parse into visual cards if it's NOT the travel or time sections
              String lowerSection = currentSection.title.toLowerCase();
              if(!lowerSection.contains('travel') && !lowerSection.contains('time') && !lowerSection.contains('modes')) {
                 currentSection.content.add(TripItem(title, desc));
                 isCardItem = true;
              }
           }
        }
        
        // If it wasn't parsed as a card, add it as a beautifully formatted text block
        if (!isCardItem) {
            String textContent = line.replaceFirst(RegExp(r'^- \*\*'), '- ')
                                     .replaceAll('**', '')
                                     .replaceAll('*', '');
            
            // Avoid adding pure empty fluff lines
            if (textContent.trim().isNotEmpty) {
               currentSection.content.add(textContent);
            }
        }
      }
    }
    
    // If the AI somehow didn't use ANY markdown headers, ensure we return the fallback section
    if (sections.isEmpty && currentSection.content.isNotEmpty) {
       sections.add(currentSection);
    }
    
    return sections;
  }

  Widget _buildPlan() {
    final sections = _parsePlan(_tripPlan!);
    
    return ListView.builder(
      padding: const EdgeInsets.only(left: 24, right: 24, top: 32, bottom: 64),
      // Large cacheExtent keeps cards alive while scrolling so images don't disappear
      cacheExtent: 5000,
      itemCount: sections.length,
      itemBuilder: (context, index) {
         final section = sections[index];
         
         return Padding(
           padding: const EdgeInsets.only(bottom: 32.0),
           child: Column(
             crossAxisAlignment: CrossAxisAlignment.start,
             children: [
               // Custom Glowing Header
               Text(
                 section.title.toUpperCase(), 
                 style: const TextStyle(
                   color: Colors.blueAccent, 
                   fontSize: 14, 
                   fontWeight: FontWeight.w900,
                   letterSpacing: 1.5,
                 )
               ),
               const SizedBox(height: 16),
               
               // Render the content blocks
               ...section.content.map((item) {
                  if (item is TripItem) {
                     return Padding(
                       padding: const EdgeInsets.only(bottom: 24.0),
                       child: ModernImageCard(title: item.title, description: item.description),
                     );
                  } else {
                     // Standard text paragraph/list formatting
                     String text = item as String;
                     bool isBullet = text.startsWith('- ');
                     
                     return Padding(
                       padding: const EdgeInsets.only(bottom: 12.0),
                       child: Row(
                         crossAxisAlignment: CrossAxisAlignment.start,
                         children: [
                           if (isBullet)
                             const Padding(
                               padding: EdgeInsets.only(top: 8.0, right: 12.0, left: 4.0),
                               child: Icon(Icons.circle, size: 6, color: Colors.blueAccent),
                             ),
                           Expanded(
                             child: Text(
                               isBullet ? text.substring(2) : text,
                               style: TextStyle(
                                 color: Colors.white.withValues(alpha: 0.8), 
                                 fontSize: 16, 
                                 height: 1.6,
                                 fontWeight: isBullet ? FontWeight.w500 : FontWeight.normal
                               ),
                             ),
                           ),
                         ],
                       ),
                     );
                  }
               }),
             ]
           ),
         );
      }
    );
  }
}

class TripSection {
  final String title;
  final List<dynamic> content;
  TripSection(this.title, this.content);
}

class TripItem {
  final String title;
  final String description;
  TripItem(this.title, this.description);
}

class ModernImageCard extends StatefulWidget {
  final String title;
  final String description;

  const ModernImageCard({super.key, required this.title, required this.description});

  @override
  State<ModernImageCard> createState() => _ModernImageCardState();
}

class _ModernImageCardState extends State<ModernImageCard>
    with AutomaticKeepAliveClientMixin {
  String? imageUrl;
  bool isSearching = true;
  bool imageFailed = false;
  int _retryCount = 0; // incremented to force Image.network to reload

  // AutomaticKeepAliveClientMixin: keep the widget alive while off-screen so
  // images don't get discarded and re-fetched every time the user scrolls.
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fetchImage();
  }

  Future<void> _fetchImage() async {
    if (mounted) setState(() { isSearching = true; imageFailed = false; });
    // fetchImageUrl always returns a non-null String (Picsum as guaranteed fallback)
    final url = await ImageSearchService().fetchImageUrl(widget.title);
    if (mounted) {
      setState(() {
        imageUrl = url;
        isSearching = false;
      });
    }
  }

  void _retry() {
    // Evict from image cache so Flutter doesn't serve the stale broken image
    if (imageUrl != null) {
      PaintingBinding.instance.imageCache.evict(NetworkImage(imageUrl!));
    }
    // Also re-fetch from service (which might pick a different Wikipedia result)
    ImageSearchService().clearCache();
    setState(() {
      imageFailed = false;
      _retryCount++;
    });
    _fetchImage();
  }

  Future<void> _launchMaps() async {
    final query = Uri.encodeComponent(widget.title);
    final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$query');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return GestureDetector(
      onTap: _launchMaps,
      child: Container(
        height: 240,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: [
             BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 10))
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Background Image — use _retryCount in key to force reload on retry
              if (imageUrl != null && !imageFailed)
                 Image.network(
                    imageUrl!,
                    key: ValueKey('${widget.title}_$_retryCount'),
                    fit: BoxFit.cover,
                    loadingBuilder: (ctx, child, progress) {
                       if (progress == null) return child;
                       return const Center(child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2));
                    },
                    errorBuilder: (ctx, err, stack) {
                       // Mark as failed so we show the retry button
                       WidgetsBinding.instance.addPostFrameCallback((_) {
                         if (mounted) setState(() => imageFailed = true);
                       });
                       return const SizedBox.shrink();
                    },
                 )
              else if (isSearching)
                 const Center(child: CircularProgressIndicator(color: Colors.white24, strokeWidth: 2))
              else
                 const Center(child: Icon(Icons.place, color: Colors.white10, size: 80)),

              // Retry button overlay — shown only when image fails
              if (imageFailed)
                Center(
                  child: GestureDetector(
                    onTap: _retry,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: Colors.white24),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh_rounded, color: Colors.white70, size: 16),
                          SizedBox(width: 8),
                          Text('Retry Image', style: TextStyle(color: Colors.white70, fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ),

              // Glassmorphic Gradient Overlay (darker for readability)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.4),
                        Colors.black.withValues(alpha: 0.95),
                      ],
                      stops: const [0.4, 0.7, 1.0],
                    )
                  ),
                ),
              ),

              // Content & Heavy Blur
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                      color: Colors.black.withValues(alpha: 0.3), // Tonal dark backing
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                           Row(
                             crossAxisAlignment: CrossAxisAlignment.start,
                             children: [
                               Expanded(
                                 child: Text(
                                   widget.title,
                                   style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                                   maxLines: 1,
                                   overflow: TextOverflow.ellipsis,
                                 ),
                               ),
                               const SizedBox(width: 12),
                               Container(
                                 decoration: BoxDecoration(
                                   color: Colors.white.withValues(alpha: 0.15),
                                   borderRadius: BorderRadius.circular(20),
                                   border: Border.all(color: Colors.white24)
                                 ),
                                 padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                 child: const Row(
                                   children: [
                                      Icon(Icons.directions, size: 14, color: Colors.white),
                                      SizedBox(width: 6),
                                      Text('MAPS', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5))
                                   ],
                                 ),
                               )
                             ],
                           ),
                           const SizedBox(height: 8),
                           Text(
                             widget.description,
                             style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 15, height: 1.4),
                             maxLines: 2,
                             overflow: TextOverflow.ellipsis,
                           ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
