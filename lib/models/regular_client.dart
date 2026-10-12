// models/regular_client.dart
//
// A regular client's reusable allocation plan: `regularClients/{id}`.
//
// The plan points at a map in the gallery (by id, never a copy, so polygon
// edits there flow through) and divides its polygons between numbered
// distributor slots. Each slot has one bucket per man day, and each bucket
// holds the polygon ids that slot works that day. Real distributors are only
// chosen when a Job List job is created from the plan.
//
// A polygon may sit in several slots or days — two people sharing one area is
// normal — so nothing here enforces exclusivity.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Colours handed to new slots in order. Stored on the slot once chosen, so a
/// slot keeps its colour when an earlier one is removed.
const List<Color> kRegularClientSlotPalette = [
  Color(0xFF1E88E5), // blue
  Color(0xFFE53935), // red
  Color(0xFF43A047), // green
  Color(0xFFFB8C00), // orange
  Color(0xFF8E24AA), // purple
  Color(0xFF00ACC1), // cyan
  Color(0xFFD81B60), // pink
  Color(0xFF6D4C41), // brown
  Color(0xFFC0CA33), // lime
  Color(0xFF3949AB), // indigo
];

class RegularClientDay {
  final List<String> polygonIds;

  const RegularClientDay({this.polygonIds = const []});

  factory RegularClientDay.fromMap(Map<String, dynamic> map) =>
      RegularClientDay(
        polygonIds: List<String>.unmodifiable(
            (map['polygonIds'] as List? ?? const []).map((e) => '$e')),
      );

  Map<String, dynamic> toMap() => {'polygonIds': polygonIds};

  RegularClientDay copyWith({List<String>? polygonIds}) =>
      RegularClientDay(polygonIds: polygonIds ?? this.polygonIds);
}

class RegularClientSlot {
  final String id;
  final String label;
  final int colorValue;
  final List<RegularClientDay> days;

  const RegularClientSlot({
    required this.id,
    required this.label,
    required this.colorValue,
    this.days = const [RegularClientDay()],
  });

  Color get color => Color(colorValue);

  /// One schedule day per bucket.
  int get manDays => days.length;

  Set<String> get polygonIds => {for (final d in days) ...d.polygonIds};

  factory RegularClientSlot.fromMap(Map<String, dynamic> map) {
    final days = (map['days'] as List? ?? const [])
        .whereType<Map>()
        .map((d) => RegularClientDay.fromMap(Map<String, dynamic>.from(d)))
        .toList(growable: false);
    return RegularClientSlot(
      id: map['id'] as String? ?? '',
      label: map['label'] as String? ?? '',
      colorValue: (map['colorValue'] as num?)?.toInt() ??
          kRegularClientSlotPalette.first.toARGB32(),
      days: days.isEmpty ? const [RegularClientDay()] : days,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'colorValue': colorValue,
        'days': days.map((d) => d.toMap()).toList(),
      };

  RegularClientSlot copyWith({
    String? label,
    int? colorValue,
    List<RegularClientDay>? days,
  }) =>
      RegularClientSlot(
        id: id,
        label: label ?? this.label,
        colorValue: colorValue ?? this.colorValue,
        days: days ?? this.days,
      );
}

/// Where a polygon sits in a plan: one entry per slot-day holding it.
class RegularClientHolding {
  final RegularClientSlot slot;
  final int dayIndex;

  const RegularClientHolding(this.slot, this.dayIndex);

  String get label => '${slot.label} · Day ${dayIndex + 1}';
}

class RegularClient {
  final String id;
  final String name;
  final List<String> aliases;
  final String mapId;
  final String mapMonthKey;
  final String mapName;
  final List<RegularClientSlot> slots;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const RegularClient({
    required this.id,
    required this.name,
    this.aliases = const [],
    required this.mapId,
    required this.mapMonthKey,
    this.mapName = '',
    this.slots = const [],
    this.createdAt,
    this.updatedAt,
  });

  int get totalManDays => slots.fold(0, (total, s) => total + s.manDays);

  /// Every slot-day holding [polygonId], in slot then day order.
  List<RegularClientHolding> holdingsOf(String polygonId) => [
        for (final s in slots)
          for (var i = 0; i < s.days.length; i++)
            if (s.days[i].polygonIds.contains(polygonId))
              RegularClientHolding(s, i),
      ];

  /// Every polygon id the plan references.
  Set<String> get allocatedIds => {for (final s in slots) ...s.polygonIds};

  /// The ids in [allIds] that no slot holds.
  List<String> unallocatedIds(Iterable<String> allIds) {
    final held = allocatedIds;
    return [for (final id in allIds) if (!held.contains(id)) id];
  }

  /// The ids the plan references that are not in [allIds] — areas deleted
  /// from the gallery map since they were allocated.
  Set<String> missingIds(Iterable<String> allIds) =>
      allocatedIds.difference(allIds.toSet());

  /// A new slot, numbered after the highest existing one, with the next
  /// palette colour not already in use.
  RegularClientSlot newSlot() {
    var n = slots.length + 1;
    final labels = {for (final s in slots) s.label};
    while (labels.contains('Distributor $n')) {
      n++;
    }
    final used = {for (final s in slots) s.colorValue};
    final colour = kRegularClientSlotPalette.firstWhere(
      (c) => !used.contains(c.toARGB32()),
      orElse: () => kRegularClientSlotPalette[
          slots.length % kRegularClientSlotPalette.length],
    );
    return RegularClientSlot(
      id: 'slot_${DateTime.now().microsecondsSinceEpoch}',
      label: 'Distributor $n',
      colorValue: colour.toARGB32(),
    );
  }

  /// This plan with [polygonId] toggled in slot [slotId] on [dayIndex].
  RegularClient togglePolygon(String slotId, int dayIndex, String polygonId) {
    return copyWith(slots: [
      for (final s in slots)
        if (s.id != slotId)
          s
        else
          s.copyWith(days: [
            for (var i = 0; i < s.days.length; i++)
              if (i != dayIndex)
                s.days[i]
              else if (s.days[i].polygonIds.contains(polygonId))
                s.days[i].copyWith(
                    polygonIds: [
                  for (final id in s.days[i].polygonIds)
                    if (id != polygonId) id
                ])
              else
                s.days[i].copyWith(
                    polygonIds: [...s.days[i].polygonIds, polygonId]),
          ]),
    ]);
  }

  /// This plan with [polygonIds] added to slot [slotId] on [dayIndex] (ones
  /// already there are left alone).
  RegularClient addPolygons(
      String slotId, int dayIndex, Iterable<String> polygonIds) {
    return copyWith(slots: [
      for (final s in slots)
        if (s.id != slotId)
          s
        else
          s.copyWith(days: [
            for (var i = 0; i < s.days.length; i++)
              if (i != dayIndex)
                s.days[i]
              else
                s.days[i].copyWith(polygonIds: [
                  ...s.days[i].polygonIds,
                  for (final id in polygonIds)
                    if (!s.days[i].polygonIds.contains(id)) id,
                ]),
          ]),
    ]);
  }

  RegularClient replaceSlot(RegularClientSlot slot) => copyWith(slots: [
        for (final s in slots) s.id == slot.id ? slot : s,
      ]);

  RegularClient removeSlot(String slotId) =>
      copyWith(slots: [for (final s in slots) if (s.id != slotId) s]);

  factory RegularClient.fromFirestore(
      DocumentSnapshot<Map<String, dynamic>> doc) =>
      RegularClient.fromMap(doc.id, doc.data() ?? const {});

  factory RegularClient.fromMap(String id, Map<String, dynamic> map) {
    DateTime? ts(Object? v) => v is Timestamp ? v.toDate() : null;
    return RegularClient(
      id: id,
      name: map['name'] as String? ?? '',
      aliases: List<String>.unmodifiable(
          (map['aliases'] as List? ?? const []).map((e) => '$e')),
      mapId: map['mapId'] as String? ?? '',
      mapMonthKey: map['mapMonthKey'] as String? ?? '',
      mapName: map['mapName'] as String? ?? '',
      slots: List<RegularClientSlot>.unmodifiable(
        (map['slots'] as List? ?? const []).whereType<Map>().map(
            (s) => RegularClientSlot.fromMap(Map<String, dynamic>.from(s))),
      ),
      createdAt: ts(map['createdAt']),
      updatedAt: ts(map['updatedAt']),
    );
  }

  /// Timestamps are set by the service, not here.
  Map<String, dynamic> toMap() => {
        'name': name,
        'aliases': aliases,
        'mapId': mapId,
        'mapMonthKey': mapMonthKey,
        'mapName': mapName,
        'slots': slots.map((s) => s.toMap()).toList(),
      };

  RegularClient copyWith({
    String? name,
    List<String>? aliases,
    String? mapId,
    String? mapMonthKey,
    String? mapName,
    List<RegularClientSlot>? slots,
  }) =>
      RegularClient(
        id: id,
        name: name ?? this.name,
        aliases: aliases ?? this.aliases,
        mapId: mapId ?? this.mapId,
        mapMonthKey: mapMonthKey ?? this.mapMonthKey,
        mapName: mapName ?? this.mapName,
        slots: slots ?? this.slots,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}
