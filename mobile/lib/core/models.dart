class InstalledGame {
  const InstalledGame({
    required this.id,
    required this.name,
    required this.description,
    required this.version,
    required this.installedAt,
  });
  final String id;
  final String name;
  final String description;
  final int version;
  final DateTime installedAt;
}

class ContentBlock {
  const ContentBlock({required this.kind, required this.value});
  final String kind;
  final String value;
}

class PlayerRecord {
  const PlayerRecord({
    required this.id,
    required this.code,
    required this.title,
    required this.groupName,
    required this.blocks,
  });
  final String id;
  final String code;
  final String title;
  final String? groupName;
  final List<ContentBlock> blocks;
}

enum LookupStatus { opened, wrong, locked, invalid }

class LookupResult {
  const LookupResult({
    required this.status,
    this.record,
    required this.wrongAttempts,
    this.lockedUntil,
  });
  final LookupStatus status;
  final PlayerRecord? record;
  final int wrongAttempts;
  final DateTime? lockedUntil;
}

class PlayerException implements Exception {
  const PlayerException(this.message);
  final String message;
  @override
  String toString() => message;
}
