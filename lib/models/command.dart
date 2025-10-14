/// Base command interface for implementing the Command pattern
/// Used for undo/redo functionality across the application
abstract class Command {
  /// Execute the command
  Future<void> execute();

  /// Undo the command (reverse the operation)
  Future<void> undo();

  /// Get a description of what this command does (for debugging/UI)
  String get description;

  /// Timestamp when the command was created
  final DateTime timestamp = DateTime.now();
}

/// Base class for commands that operate on data
abstract class DataCommand extends Command {
  /// The data affected by this command
  final Map<String, dynamic> originalData;
  final Map<String, dynamic>? newData;

  DataCommand({
    required this.originalData,
    this.newData,
  });
}

/// Enum for different types of operations
enum OperationType {
  add,
  edit,
  delete,
  move,
  import,
  export,
}

/// Base class for commands that modify specific entities
abstract class EntityCommand<T> extends Command {
  /// The type of operation being performed
  final OperationType operation;

  /// The entity being operated on (before changes)
  final T? originalEntity;

  /// The entity after changes (for add/edit operations)
  final T? modifiedEntity;

  /// Additional context for the operation
  final Map<String, dynamic> context;

  EntityCommand({
    required this.operation,
    this.originalEntity,
    this.modifiedEntity,
    this.context = const {},
  });

  @override
  String get description {
    final entityType = T.toString();
    switch (operation) {
      case OperationType.add:
        return 'Add $entityType';
      case OperationType.edit:
        return 'Edit $entityType';
      case OperationType.delete:
        return 'Delete $entityType';
      case OperationType.move:
        return 'Move $entityType';
      case OperationType.import:
        return 'Import $entityType';
      case OperationType.export:
        return 'Export $entityType';
    }
  }
}
