import 'dart:async';

import 'otel_flutter_breadcrumb_entry.dart';

/// Listener invoked for each recorded breadcrumb.
typedef OtelFlutterBreadcrumbListener =
    FutureOr<void> Function(OtelFlutterBreadcrumbEntry entry);

/// Listener invoked for captured Flutter error snapshots.
typedef OtelFlutterErrorListener =
    FutureOr<void> Function(OtelFlutterErrorSnapshot snapshot);

/// Immutable snapshot of a captured Flutter error.
final class OtelFlutterErrorSnapshot {
  /// Creates an error snapshot.
  const OtelFlutterErrorSnapshot({
    required this.source,
    required this.error,
    required this.stackTrace,
    required this.attributes,
    required this.breadcrumbs,
  });

  /// Error source identifier.
  final String source;

  /// Captured error object.
  final Object error;

  /// Captured stack trace, if available.
  final StackTrace? stackTrace;

  /// Structured attributes derived from the error.
  final Map<String, Object> attributes;

  /// Breadcrumbs captured before the error.
  final List<OtelFlutterBreadcrumbEntry> breadcrumbs;
}

/// Global listener hub for Flutter breadcrumb and error callbacks.
final class OtelFlutterErrorHooks {
  static OtelFlutterBreadcrumbListener? _breadcrumbListener;
  static OtelFlutterErrorListener? _frameworkErrorListener;
  static OtelFlutterErrorListener? _platformErrorListener;

  /// Configures breadcrumb and error listeners.
  static void configure({
    OtelFlutterBreadcrumbListener? breadcrumbListener,
    OtelFlutterErrorListener? frameworkErrorListener,
    OtelFlutterErrorListener? platformErrorListener,
  }) {
    _breadcrumbListener = breadcrumbListener;
    _frameworkErrorListener = frameworkErrorListener;
    _platformErrorListener = platformErrorListener;
  }

  /// Se há listener de erro de framework configurado. A captura de erro usa
  /// isto para montar os atributos de uma ocorrência suprimida pelo
  /// limitador só quando alguém vai recebê-los.
  static bool get hasFrameworkErrorListener => _frameworkErrorListener != null;

  /// Se há listener de erro do platform dispatcher configurado. Ver
  /// [hasFrameworkErrorListener].
  static bool get hasPlatformErrorListener => _platformErrorListener != null;

  /// Dispatches a breadcrumb to the configured listener.
  static void dispatchBreadcrumb(OtelFlutterBreadcrumbEntry entry) {
    final listener = _breadcrumbListener;
    if (listener == null) {
      return;
    }

    final result = listener(entry);
    if (result is Future<void>) {
      unawaited(result);
    }
  }

  /// Dispatches a framework error snapshot to the configured listener.
  static void dispatchFrameworkError(OtelFlutterErrorSnapshot snapshot) {
    final listener = _frameworkErrorListener;
    if (listener == null) {
      return;
    }

    final result = listener(snapshot);
    if (result is Future<void>) {
      unawaited(result);
    }
  }

  /// Dispatches a platform dispatcher error snapshot to the listener.
  static void dispatchPlatformError(OtelFlutterErrorSnapshot snapshot) {
    final listener = _platformErrorListener;
    if (listener == null) {
      return;
    }

    final result = listener(snapshot);
    if (result is Future<void>) {
      unawaited(result);
    }
  }

  /// Removes all configured listeners.
  static void clear() {
    _breadcrumbListener = null;
    _frameworkErrorListener = null;
    _platformErrorListener = null;
  }
}
