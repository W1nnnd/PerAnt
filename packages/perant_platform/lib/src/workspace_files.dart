// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';

/// Receipt for bytes newly published by an import, not a read of a live file.
/// A running desktop may edit or remove [path] after this operation returns.
final class LinuxFileImport {
  const LinuxFileImport({
    required this.path,
    required this.sha256,
    required this.sizeBytes,
  });

  final String path;
  final String sha256;
  final int sizeBytes;

  factory LinuxFileImport.fromMap(Map<Object?, Object?> map) {
    final path = map['path'];
    final sha256 = map['sha256'];
    final sizeBytes = map['sizeBytes'];
    if (path is! String ||
        !RegExp(
          r'^/workspace/web-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.md$',
        ).hasMatch(path) ||
        sha256 is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        sizeBytes is! int ||
        sizeBytes < 0 ||
        sizeBytes > 262144) {
      throw const FormatException('Invalid native import receipt.');
    }
    return LinuxFileImport(path: path, sha256: sha256, sizeBytes: sizeBytes);
  }
}

/// The actual directory entries returned from the idle native workspace.
final class LinuxDirectoryListing {
  const LinuxDirectoryListing({
    required this.path,
    required this.entries,
    required this.truncated,
  });

  final String path;
  final List<LinuxFileEntry> entries;
  final bool truncated;

  factory LinuxDirectoryListing.fromMap(Map<Object?, Object?> map) {
    final path = _nativePath(map['path']);
    final rawEntries = map['entries'];
    final truncated = map['truncated'];
    if (rawEntries is! List || rawEntries.length > 500 || truncated is! bool) {
      throw const FormatException('Invalid directory listing.');
    }
    final entries = <LinuxFileEntry>[];
    final names = <String>{};
    for (final item in rawEntries) {
      if (item is! Map) throw const FormatException('Invalid file entry.');
      final entry = LinuxFileEntry.fromMap(Map<Object?, Object?>.from(item));
      if (entry.path != '$path/${entry.name}' || !names.add(entry.name)) {
        throw const FormatException(
            'Directory entry does not belong to parent.');
      }
      entries.add(entry);
    }
    return LinuxDirectoryListing(
      path: path,
      entries: List.unmodifiable(entries),
      truncated: truncated,
    );
  }
}

final class LinuxFileEntry {
  const LinuxFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAtEpochMs,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final int modifiedAtEpochMs;

  factory LinuxFileEntry.fromMap(Map<Object?, Object?> map) {
    final name = map['name'];
    final path = _nativePath(map['path'], allowRoot: false);
    final isDirectory = map['isDirectory'];
    final sizeBytes = map['sizeBytes'];
    final modified = map['modifiedAtEpochMs'];
    if (name is! String ||
        name != path.split('/').last ||
        isDirectory is! bool ||
        sizeBytes is! int ||
        sizeBytes < 0 ||
        (isDirectory && sizeBytes != 0) ||
        modified is! int ||
        modified < 0) {
      throw const FormatException('Invalid native file metadata.');
    }
    return LinuxFileEntry(
      name: name,
      path: path,
      isDirectory: isDirectory,
      sizeBytes: sizeBytes,
      modifiedAtEpochMs: modified,
    );
  }
}

/// Strict UTF-8 content and its native byte digest for conflict-aware saves.
final class LinuxTextFile {
  const LinuxTextFile({
    required this.path,
    required this.content,
    required this.sha256,
    required this.sizeBytes,
  });

  final String path;
  final String content;
  final String sha256;
  final int sizeBytes;

  factory LinuxTextFile.fromMap(Map<Object?, Object?> map) {
    final path = _nativePath(map['path'], allowRoot: false);
    final content = map['content'];
    final digest = map['sha256'];
    final size = map['sizeBytes'];
    if (content is! String || digest is! String || size is! int) {
      throw const FormatException('Invalid native text file.');
    }
    try {
      validateLinuxFileContent(content);
    } on ArgumentError {
      throw const FormatException('Invalid native UTF-8 file content.');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        size != utf8.encode(content).length) {
      throw const FormatException('Invalid native file size or digest.');
    }
    return LinuxTextFile(
      path: path,
      content: content,
      sha256: digest,
      sizeBytes: size,
    );
  }
}

/// Shared input validation; native code independently checks this contract.
String normalizeLinuxWorkspacePath(String value, {bool allowRoot = true}) {
  final bytes = utf8.encode(value);
  if (bytes.isEmpty ||
      bytes.length > 1024 ||
      utf8.decode(bytes) != value ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\\\u2028\u2029]').hasMatch(value)) {
    throw ArgumentError.value(value, 'path', 'Invalid workspace path.');
  }
  if (value == '/workspace') {
    if (!allowRoot)
      throw ArgumentError('A file or child directory is required.');
    return value;
  }
  final relative = value.startsWith('/workspace/')
      ? value.substring('/workspace/'.length)
      : value;
  final components = relative.split('/');
  if (relative.startsWith('/') ||
      components.length > 32 ||
      components.any((part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part == '.perant-tasks' ||
          part.startsWith('.perant-write-') ||
          utf8.encode(part).length > 255)) {
    throw ArgumentError.value(value, 'path', 'Path must stay in /workspace.');
  }
  return '/workspace/$relative';
}

void validateLinuxFileContent(String value) {
  final bytes = utf8.encode(value);
  if (bytes.length > 262144 ||
      utf8.decode(bytes) != value ||
      value.contains('\u0000')) {
    throw ArgumentError(
        'Text must be valid UTF-8 without NUL, at most 256 KiB.');
  }
}

String _nativePath(Object? value, {bool allowRoot = true}) {
  if (value is! String || !value.startsWith('/workspace')) {
    throw const FormatException('Invalid native workspace path.');
  }
  try {
    final normalized = normalizeLinuxWorkspacePath(value, allowRoot: allowRoot);
    if (normalized != value) throw const FormatException('Noncanonical path.');
    return normalized;
  } on ArgumentError {
    throw const FormatException('Invalid native workspace path.');
  }
}
