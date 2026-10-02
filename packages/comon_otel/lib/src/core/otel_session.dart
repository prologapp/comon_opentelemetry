import 'dart:math';

import 'package:meta/meta.dart';

/// Isolate-lifetime session identity, independent from any [Otel] instance.
///
/// The session id is minted lazily, once per isolate — Dart statics are
/// isolate-local, not process-global: the first read wins and the value
/// survives a warm `Otel.init` re-run on that same isolate (state lives
/// here, not on the SDK instance).
///
/// Any other isolate starts with fresh static state and mints its own id,
/// whether it runs in a new process or alongside the main isolate in the
/// same process (e.g. a background isolate spawned by a plugin such as a
/// work scheduler). The id therefore identifies an isolate, not an app
/// process or a user session; callers that need one id per process must
/// decide which isolate owns it (e.g. only the isolate that tracks app
/// startup reads and persists it, and passes it as `previousSessionId`).
///
/// Not exported from the package barrel: [Otel.sessionId] is the public
/// surface. Import this class directly (`package:comon_otel/src/core/...`)
/// only from tests, to use [resetForTesting].
final class OtelSession {
  OtelSession._();

  static String? _sessionId;
  static bool _rotationEmitted = false;
  static final Random _random = Random.secure();

  /// The current isolate's session id, minting one on first access.
  static String get id => _sessionId ??= _generateUuidV4();

  /// Marks the session-rotation span as emitted for this isolate.
  ///
  /// Returns `true` the first time it is called (caller should emit the
  /// span) and `false` on every subsequent call, so the rotation span is
  /// emitted at most once per isolate.
  static bool claimRotationEmission() {
    if (_rotationEmitted) {
      return false;
    }
    _rotationEmitted = true;
    return true;
  }

  /// Resets all session state. Test-only — production code must never call
  /// this, since it defeats the "one id per isolate" contract.
  @visibleForTesting
  static void resetForTesting() {
    _sessionId = null;
    _rotationEmitted = false;
  }

  static String _generateUuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));

    // Version 4: top nibble of byte 6 is 0100.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Variant 1 (RFC 4122): top two bits of byte 8 are 10.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    String hex(int start, int end) {
      final buffer = StringBuffer();
      for (var i = start; i < end; i += 1) {
        buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
      }
      return buffer.toString();
    }

    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}
