import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as latlong;
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class LocationPickerPage extends StatefulWidget {
  final latlong.LatLng? initialLocation;

  const LocationPickerPage({super.key, this.initialLocation});

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  final MapController _mapController = MapController();
  final TextEditingController _searchController = TextEditingController();
  latlong.LatLng? _pickedLocation;
  bool _isSearching = false;
  List<dynamic> _searchResults = [];
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _pickedLocation = widget.initialLocation ?? const latlong.LatLng(0, 0);
  }

  void _onSearchQueryChanged(String query) {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    
    if (query.length < 3) {
       setState(() { _searchResults = []; });
       return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 700), () async {
      setState(() => _isSearching = true);
      
      try {
        // Use free public Nominatim API
        final uri = Uri.parse('https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&addressdetails=1&limit=5');
        final response = await http.get(uri, headers: {
           'User-Agent': 'ninta-gallery-app'
        });

        if (response.statusCode == 200) {
           setState(() {
              _searchResults = jsonDecode(response.body);
           });
        }
      } catch(e) {
        print("Nominatim Search Error: $e");
      } finally {
        setState(() => _isSearching = false);
      }
    });
  }

  void _onResultTapped(dynamic result) {
     final double lat = double.parse(result['lat']);
     final double lng = double.parse(result['lon']);
     final loc = latlong.LatLng(lat, lng);
     
     _mapController.move(loc, 14.0);
     setState(() {
        _pickedLocation = loc;
        _searchResults = [];
        _searchController.text = result['display_name'];
     });
     
     // Close keyboard
     FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black54,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _pickedLocation!,
              initialZoom: widget.initialLocation != null ? 14.0 : 2.0,
              interactionOptions: const InteractionOptions(
                 flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
              onPositionChanged: (position, hasGesture) {
                 if (hasGesture && position.center != null) {
                    setState(() {
                       _pickedLocation = position.center;
                    });
                 }
              }
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.ninta',
              ),
            ],
          ),
          
          // Center Marker (Crosshair)
          const Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 40.0), // Adjust for pin tail
              child: Icon(
                Icons.location_on,
                size: 50,
                color: Colors.redAccent,
                shadows: [Shadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 5))],
              ),
            ),
          ),

          // Search Bar Overlay
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 60.0, vertical: 8.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                         color: Colors.grey[900]?.withOpacity(0.9),
                         borderRadius: BorderRadius.circular(30),
                         boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 10)]
                      ),
                      child: TextField(
                        controller: _searchController,
                        onChanged: _onSearchQueryChanged,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                           hintText: 'Search for a place...',
                           hintStyle: const TextStyle(color: Colors.white54),
                           prefixIcon: const Icon(Icons.search, color: Colors.white70),
                           border: InputBorder.none,
                           contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                           suffixIcon: _isSearching ? const Padding(
                             padding: EdgeInsets.all(12.0),
                             child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                           ) : (_searchController.text.isNotEmpty ? IconButton(
                             icon: const Icon(Icons.clear, color: Colors.white54),
                             onPressed: () {
                                _searchController.clear();
                                setState(() { _searchResults = []; });
                             }
                           ) : null),
                        ),
                      ),
                    ),
                    
                    if (_searchResults.isNotEmpty)
                      Container(
                         margin: const EdgeInsets.only(top: 8),
                         constraints: BoxConstraints(maxHeight: 250),
                         decoration: BoxDecoration(
                           color: Colors.grey[900]?.withOpacity(0.95),
                           borderRadius: BorderRadius.circular(16)
                         ),
                         child: ListView.separated(
                           padding: EdgeInsets.zero,
                           shrinkWrap: true,
                           itemCount: _searchResults.length,
                           separatorBuilder: (_,__) => Divider(color: Colors.white12, height: 1),
                           itemBuilder: (context, index) {
                              final result = _searchResults[index];
                              return ListTile(
                                leading: const Icon(Icons.place, color: Colors.white70),
                                title: Text(result['display_name'] ?? '', style: const TextStyle(color: Colors.white, fontSize: 14)),
                                onTap: () => _onResultTapped(result),
                              );
                           },
                         ),
                      )
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.blueAccent,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.check),
        label: const Text('Set Location', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () {
           Navigator.pop(context, _pickedLocation);
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
