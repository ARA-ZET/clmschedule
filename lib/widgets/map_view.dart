import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../env.dart';

class MapView extends StatefulWidget {
  final String? initialLocation;
  final List<LatLng>? polygonPoints;
  final Color polygonColor;
  final String? title;

  const MapView({
    super.key,
    this.initialLocation,
    this.polygonPoints,
    this.title,
    this.polygonColor = const Color(0x40FF0000), // Semi-transparent red
  });

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  GoogleMapController? _controller;
  Set<Polygon> _polygons = {};
  LatLng _center = const LatLng(0, 0); // Will be updated when map is created

  @override
  void initState() {
    super.initState();
    _initializeMap();
  }

  Future<void> _initializeMap() async {
    if (widget.polygonPoints != null && widget.polygonPoints!.isNotEmpty) {
      // If polygon points are provided, center the map on the polygon's center
      double lat = 0;
      double lng = 0;
      for (var point in widget.polygonPoints!) {
        lat += point.latitude;
        lng += point.longitude;
      }
      _center = LatLng(
        lat / widget.polygonPoints!.length,
        lng / widget.polygonPoints!.length,
      );

      // Create the polygon
      _polygons.add(
        Polygon(
          polygonId: const PolygonId('workArea'),
          points: widget.polygonPoints!,
          fillColor: widget.polygonColor,
          strokeColor: widget.polygonColor.withOpacity(1.0),
          strokeWidth: 2,
        ),
      );
    } else if (widget.initialLocation != null) {
      // TODO: Implement geocoding to convert address to coordinates
      // For now, we'll use a default location
      _center = const LatLng(0, 0);
    }

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.title != null ? AppBar(title: Text(widget.title!)) : null,
      body: Builder(
        builder: (context) {
          // // Check if we're on desktop (macOS/Linux/Windows)
          // if (defaultTargetPlatform == TargetPlatform.macOS ||
          //     defaultTargetPlatform == TargetPlatform.linux ||
          //     defaultTargetPlatform == TargetPlatform.windows) {
          //   return Center(
          //     child: Column(
          //       mainAxisAlignment: MainAxisAlignment.center,
          //       children: [
          //         const Icon(Icons.map_outlined, size: 48, color: Colors.grey),
          //         const SizedBox(height: 16),
          //         Text(
          //           'Maps are not supported on ${defaultTargetPlatform.name}',
          //           style: Theme.of(context).textTheme.titleMedium,
          //         ),
          //         const SizedBox(height: 8),
          //         if (widget.initialLocation != null)
          //           TextButton(
          //             onPressed: () async {
          //               final url = Uri.parse(widget.initialLocation!);
          //               if (await canLaunchUrl(url)) {
          //                 await launchUrl(url);
          //               }
          //             },
          //             child: const Text('Open in Browser'),
          //           ),
          //       ],
          //     ),
          //   );
          // }

          // For mobile platforms, show the Google Map
          return GoogleMap(
            onMapCreated: (controller) {
              _controller = controller;
            },
            initialCameraPosition: CameraPosition(target: _center, zoom: 15),
            polygons: _polygons,
            mapType: MapType.normal,
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}
