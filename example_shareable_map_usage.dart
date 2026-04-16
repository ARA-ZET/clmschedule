// ignore_for_file: uri_does_not_exist, undefined_method, undefined_identifier
import 'package:flutter/material.dart';
// NOTE: This example still uses provider package syntax.
// TODO: Update to use Riverpod when needed.
// import 'package:provider/provider.dart';
import 'lib/shareable_maps.dart';

/// Example: How to integrate ShareableMapEditor into your app
///
/// This example shows how to:
/// 1. Set up the provider
/// 2. Navigate to the map editor
/// 3. Use the map editor widget

void main() {
  runApp(const ShareableMapExample());
}

class ShareableMapExample extends StatelessWidget {
  const ShareableMapExample({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ShareableMapProvider()),
        // Add other providers as needed
      ],
      child: MaterialApp(
        title: 'Shareable Map Example',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          useMaterial3: true,
        ),
        home: const HomePage(),
        routes: {
          '/map-editor': (context) => const ShareableMapEditor(),
        },
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shareable Maps Demo'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton.icon(
              onPressed: () => _createNewMap(context),
              icon: const Icon(Icons.add),
              label: const Text('Create New Map'),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _openExistingMap(context),
              icon: const Icon(Icons.map),
              label: const Text('Open Example Map'),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _importKmlMap(context),
              icon: const Icon(Icons.upload_file),
              label: const Text('Import from KML'),
            ),
          ],
        ),
      ),
    );
  }

  void _createNewMap(BuildContext context) {
    // Create a new map and navigate to editor
    final provider = context.read<ShareableMapProvider>();
    provider.createNewMap(
      name: 'My New Map',
      description: 'Created from example',
    );
    Navigator.pushNamed(context, '/map-editor');
  }

  void _openExistingMap(BuildContext context) {
    // Load an example map
    final provider = context.read<ShareableMapProvider>();

    // Create an example map with some data
    final exampleMap = ShareableMap.create(
      name: 'Example Map',
      description: 'Pre-loaded example with layers',
    );

    // Add a layer with some example data
    final layer = MapLayer.create(
      name: 'Example Layer',
      defaultColor: Colors.blue,
    );

    final mapWithLayer = exampleMap.addLayer(layer);

    provider.loadMap(mapWithLayer);
    Navigator.pushNamed(context, '/map-editor');
  }

  void _importKmlMap(BuildContext context) {
    // TODO: Implement KML import
    // This will be implemented in the next phase
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('KML import coming soon in next update'),
      ),
    );
  }
}

/// Example: Using the map editor directly in a screen
class DirectMapEditorExample extends StatefulWidget {
  const DirectMapEditorExample({super.key});

  @override
  State<DirectMapEditorExample> createState() => _DirectMapEditorExampleState();
}

class _DirectMapEditorExampleState extends State<DirectMapEditorExample> {
  late ShareableMapProvider _mapProvider;

  @override
  void initState() {
    super.initState();
    _mapProvider = ShareableMapProvider();

    // Create a new map on init
    _mapProvider.createNewMap(
      name: 'Direct Editor Map',
      description: 'Embedded map editor example',
    );
  }

  @override
  void dispose() {
    _mapProvider.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _mapProvider,
      child: const ShareableMapEditor(),
    );
  }
}

/// Example: Programmatically adding elements to a map
class ProgrammaticMapExample extends StatelessWidget {
  const ProgrammaticMapExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Programmatic Map')),
      body: ElevatedButton(
        onPressed: () => _createMapWithData(context),
        child: const Text('Create Map with Data'),
      ),
    );
  }

  void _createMapWithData(BuildContext context) {
    final provider = context.read<ShareableMapProvider>();

    // Create a new map
    provider.createNewMap(name: 'Programmatic Map');

    // Create a layer
    provider.createLayer(
      name: 'Delivery Routes',
      description: 'Route planning for deliveries',
      color: Colors.orange,
    );

    // Note: To add elements programmatically, you would:
    // 1. Get the current map and layer
    // 2. Create the element (polygon, polyline, point)
    // 3. Use the layer's add methods
    // 4. Update the provider with the modified map

    // Example for future implementation:
    // final currentMap = provider.currentMap;
    // final layer = provider.selectedLayer;
    // if (currentMap != null && layer != null) {
    //   final point = MapPoint.create(
    //     name: 'Delivery Point 1',
    //     position: LatLng(-33.925, 18.425),
    //   );
    //   final updatedLayer = layer.addPoint(point);
    //   provider.loadMap(currentMap.updateLayer(layer.id, updatedLayer));
    // }

    Navigator.pushNamed(context, '/map-editor');
  }
}

/// Example: Listening to map changes
class MapChangeListenerExample extends StatelessWidget {
  const MapChangeListenerExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ShareableMapProvider>(
      builder: (context, provider, child) {
        final map = provider.currentMap;

        if (map == null) {
          return const Center(child: Text('No map loaded'));
        }

        final stats = map.getStatistics();

        return Scaffold(
          appBar: AppBar(title: const Text('Map Statistics')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                title: const Text('Map Name'),
                subtitle: Text(map.name),
              ),
              ListTile(
                title: const Text('Total Layers'),
                subtitle: Text('${stats['totalLayers']}'),
              ),
              ListTile(
                title: const Text('Total Elements'),
                subtitle: Text('${stats['totalElements']}'),
              ),
              ListTile(
                title: const Text('Polygons'),
                subtitle: Text('${stats['totalPolygons']}'),
              ),
              ListTile(
                title: const Text('Polylines'),
                subtitle: Text('${stats['totalPolylines']}'),
              ),
              ListTile(
                title: const Text('Points'),
                subtitle: Text('${stats['totalPoints']}'),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pushNamed(context, '/map-editor'),
                child: const Text('Edit Map'),
              ),
            ],
          ),
        );
      },
    );
  }
}
