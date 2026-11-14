// SPDX-License-Identifier: GPL-3.0-only
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:perant_core/perant_core.dart' show CredentialStore;
export 'package:perant_core/perant_core.dart' show CredentialStore;

final class PlatformCredentialStore implements CredentialStore {
  const PlatformCredentialStore();
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String reference) => _storage.read(key: reference);
  @override
  Future<void> write(String reference, String value) =>
      _storage.write(key: reference, value: value);
  @override
  Future<void> delete(String reference) => _storage.delete(key: reference);
}

final class MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};
  @override
  Future<String?> read(String reference) async => _values[reference];
  @override
  Future<void> write(String reference, String value) async {
    _values[reference] = value;
  }

  @override
  Future<void> delete(String reference) async {
    _values.remove(reference);
  }
}

CredentialStore createCredentialStore() => const PlatformCredentialStore();
