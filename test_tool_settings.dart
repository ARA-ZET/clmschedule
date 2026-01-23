import 'package:flutter_test/flutter_test.dart';
import 'package:clmschedule/models/tool_settings.dart';
import 'package:clmschedule/models/inventory_tool.dart';
import 'package:clmschedule/providers/tool_settings_provider.dart';
import 'package:clmschedule/services/tool_settings_service.dart';

void main() {
  group('Tool Settings BaseName Tests', () {
    test('ToolRequirement uses baseName instead of toolId', () {
      // Create a tool requirement with baseName
      final toolReq = ToolRequirement(
        baseName: 'Ladder',
        category: 'Access Equipment',
        quantity: 2,
      );

      expect(toolReq.baseName, 'Ladder');
      expect(toolReq.category, 'Access Equipment');
      expect(toolReq.quantity, 2);
    });

    test('ToolRequirement serialization uses baseName', () {
      final toolReq = ToolRequirement(
        baseName: 'Squeegee',
        category: 'Cleaning Tool',
        quantity: 3,
      );

      // Convert to map
      final map = toolReq.toMap();
      expect(map['baseName'], 'Squeegee');
      expect(map['category'], 'Cleaning Tool');
      expect(map['quantity'], 3);
      expect(map.containsKey('toolId'), false); // Should not have toolId

      // Convert back from map
      final fromMap = ToolRequirement.fromMap(map);
      expect(fromMap.baseName, 'Squeegee');
      expect(fromMap.category, 'Cleaning Tool');
      expect(fromMap.quantity, 3);
    });

    test('calculateCategorizedTools matches by baseName', () {
      // Create provider with mock settings
      final provider = ToolSettingsProvider();

      // Create test settings
      final settings = ToolSettings(
        teamTools: [
          ToolRequirement(
            baseName: 'Van',
            category: 'Vehicle',
            quantity: 1,
          ),
        ],
        individualTools: [
          ToolRequirement(
            baseName: 'Squeegee',
            category: 'Cleaning Tool',
            quantity: 2,
          ),
        ],
      );

      // Create mock inventory with multiple tools with same base name
      final inventory = <InventoryTool>[
        InventoryTool(
          id: 'van1',
          toolId: 'VAN-001',
          name: 'Van #1', // baseName getter will extract 'Van'
          description: 'Large Van',
          category: 'Vehicle',
          qrCode: 'VAN-001',
          createdAt: DateTime.now(),
          toolType: ToolType.team,
        ),
        InventoryTool(
          id: 'van2',
          toolId: 'VAN-002',
          name: 'Van #2', // baseName getter will extract 'Van'
          description: 'Small Van',
          category: 'Vehicle',
          qrCode: 'VAN-002',
          createdAt: DateTime.now(),
          toolType: ToolType.team,
        ),
        InventoryTool(
          id: 'squeegee1',
          toolId: 'SQUEEGEE-001',
          name: 'Squeegee #1', // baseName getter will extract 'Squeegee'
          description: 'Small Squeegee',
          category: 'Cleaning Tool',
          qrCode: 'SQUEEGEE-001',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
        InventoryTool(
          id: 'squeegee2',
          toolId: 'SQUEEGEE-002',
          name: 'Squeegee #2', // baseName getter will extract 'Squeegee'
          description: 'Large Squeegee',
          category: 'Cleaning Tool',
          qrCode: 'SQUEEGEE-002',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
        InventoryTool(
          id: 'squeegee3',
          toolId: 'SQUEEGEE-003',
          name: 'Squeegee #3', // baseName getter will extract 'Squeegee'
          description: 'Medium Squeegee',
          category: 'Cleaning Tool',
          qrCode: 'SQUEEGEE-003',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
      ];

      // Calculate tools for 2 cleaners
      final categorized = provider.calculateCategorizedTools(2, inventory);

      // Should have 1 team tool (Van)
      expect(categorized.teamTools.length, 1);
      expect(categorized.teamTools[0].baseName, 'Van');
      expect(categorized.teamTools[0].totalQuantity, 1); // Only 1 van requested

      // Should have individual tools: 2 squeegees per cleaner * 2 cleaners = 4 squeegees
      expect(categorized.individualTools.length, 1);
      expect(categorized.individualTools[0].baseName, 'Squeegee');
      expect(categorized.individualTools[0].totalQuantity,
          3); // Limited by inventory (only 3 available)
    });

    test('Multiple base names are correctly handled', () {
      final provider = ToolSettingsProvider();

      final settings = ToolSettings(
        teamTools: [
          ToolRequirement(baseName: 'Van', category: 'Vehicle', quantity: 1),
          ToolRequirement(baseName: 'Ladder', category: 'Access', quantity: 2),
        ],
        individualTools: [
          ToolRequirement(
              baseName: 'Bucket', category: 'Container', quantity: 1),
          ToolRequirement(baseName: 'Squeegee', category: 'Tool', quantity: 2),
        ],
      );

      final inventory = <InventoryTool>[
        // Van
        InventoryTool(
          id: 'van1',
          toolId: 'VAN-001',
          name: 'Van #1',
          description: 'Van 1',
          category: 'Vehicle',
          qrCode: 'VAN-001',
          createdAt: DateTime.now(),
          toolType: ToolType.team,
        ),
        // Ladders
        InventoryTool(
          id: 'ladder1',
          toolId: 'LADDER-001',
          name: 'Ladder #1',
          description: 'Ladder 1',
          category: 'Access',
          qrCode: 'LADDER-001',
          createdAt: DateTime.now(),
          toolType: ToolType.team,
        ),
        InventoryTool(
          id: 'ladder2',
          toolId: 'LADDER-002',
          name: 'Ladder #2',
          description: 'Ladder 2',
          category: 'Access',
          qrCode: 'LADDER-002',
          createdAt: DateTime.now(),
          toolType: ToolType.team,
        ),
        // Buckets
        InventoryTool(
          id: 'bucket1',
          toolId: 'BUCKET-001',
          name: 'Bucket #1',
          description: 'Bucket 1',
          category: 'Container',
          qrCode: 'BUCKET-001',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
        InventoryTool(
          id: 'bucket2',
          toolId: 'BUCKET-002',
          name: 'Bucket #2',
          description: 'Bucket 2',
          category: 'Container',
          qrCode: 'BUCKET-002',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
        // Squeegees
        InventoryTool(
          id: 'squeegee1',
          toolId: 'SQUEEGEE-001',
          name: 'Squeegee #1',
          description: 'Squeegee 1',
          category: 'Tool',
          qrCode: 'SQUEEGEE-001',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
        InventoryTool(
          id: 'squeegee2',
          toolId: 'SQUEEGEE-002',
          name: 'Squeegee #2',
          description: 'Squeegee 2',
          category: 'Tool',
          qrCode: 'SQUEEGEE-002',
          createdAt: DateTime.now(),
          toolType: ToolType.individual,
        ),
      ];

      // For 1 cleaner
      final categorized = provider.calculateCategorizedTools(1, inventory);

      // Team tools: 1 Van + 2 Ladders = 2 groups
      expect(categorized.teamTools.length, 2);
      expect(categorized.teamTools.any((t) => t.baseName == 'Van'), true);
      expect(categorized.teamTools.any((t) => t.baseName == 'Ladder'), true);

      // Individual tools: 1 Bucket + 2 Squeegees = 2 groups
      expect(categorized.individualTools.length, 2);
      expect(
          categorized.individualTools.any((t) => t.baseName == 'Bucket'), true);
      expect(categorized.individualTools.any((t) => t.baseName == 'Squeegee'),
          true);
    });
  });
}
