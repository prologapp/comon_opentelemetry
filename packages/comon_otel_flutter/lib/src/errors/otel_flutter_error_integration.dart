import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/foundation.dart';

import '../comon_otel_flutter_instrumentation.dart';
import '../navigation/otel_flutter_route_context.dart';
import 'otel_flutter_breadcrumbs.dart';
import 'otel_flutter_error_hooks.dart';

/// Captures a framework error and forwards it into OpenTelemetry.
///
/// Telemetry never breaks the host: any failure while building attributes,
/// notifying external hooks or recording the span/log is swallowed, and the
/// [fallback] (or [FlutterError.presentError] without one) always runs
/// exactly once afterwards.
void recordFlutterFrameworkError(
  FlutterErrorDetails details, {
  String loggerName = 'comon_otel.flutter',
  FlutterExceptionHandler? fallback,
}) {
  final attributes = _guardedAttributes(
    () => _frameworkErrorAttributes(details),
    source: 'framework',
    error: details.exception,
  );
  _guarded(() {
    OtelFlutterErrorHooks.dispatchFrameworkError(
      OtelFlutterErrorSnapshot(
        source: 'framework',
        error: details.exception,
        stackTrace: details.stack,
        attributes: Map<String, Object>.unmodifiable(attributes),
        breadcrumbs: OtelFlutterBreadcrumbs.snapshot(),
      ),
    );
  });
  _guarded(() {
    _recordErrorTelemetry(
      loggerName: loggerName,
      spanName: 'flutter.error',
      logBody: 'flutter.framework_error',
      attributes: attributes,
      error: details.exception,
      stackTrace: details.stack,
      describe: details.exceptionAsString,
    );
  });

  if (fallback != null) {
    fallback(details);
    return;
  }

  FlutterError.presentError(details);
}

/// Captures a platform dispatcher error and forwards it into OpenTelemetry.
///
/// Same guarantee as [recordFlutterFrameworkError]: telemetry failures are
/// swallowed and the [fallback] always runs, with its verdict returned.
bool recordFlutterPlatformError(
  Object error,
  StackTrace stackTrace, {
  String loggerName = 'comon_otel.flutter',
  OtelPlatformErrorCallback? fallback,
}) {
  final attributes = _guardedAttributes(
    () => _platformErrorAttributes(error),
    source: 'platform_dispatcher',
    error: error,
  );
  _guarded(() {
    OtelFlutterErrorHooks.dispatchPlatformError(
      OtelFlutterErrorSnapshot(
        source: 'platform_dispatcher',
        error: error,
        stackTrace: stackTrace,
        attributes: Map<String, Object>.unmodifiable(attributes),
        breadcrumbs: OtelFlutterBreadcrumbs.snapshot(),
      ),
    );
  });
  _guarded(() {
    _recordErrorTelemetry(
      loggerName: loggerName,
      spanName: 'flutter.platform_error',
      logBody: 'flutter.platform_error',
      attributes: attributes,
      error: error,
      stackTrace: stackTrace,
      describe: error.toString,
    );
  });

  // Recording telemetry does not handle the error: only the fallback (e.g.
  // Sentry or the app's own handler) can claim it. Without one, return false
  // so the engine keeps its default reporting.
  return fallback?.call(error, stackTrace) ?? false;
}

void _guarded(void Function() body) {
  try {
    body();
  } catch (_) {
    // Telemetry never breaks the host error path.
  }
}

/// Builds the full attribute set, degrading to a minimal one when building
/// it throws (e.g. a throwing toString or informationCollector).
Map<String, Object> _guardedAttributes(
  Map<String, Object> Function() build, {
  required String source,
  required Object error,
}) {
  try {
    return build();
  } catch (_) {
    return <String, Object>{
      'flutter.error.source': source,
      SemanticAttributes.exceptionType: error.runtimeType.toString(),
    };
  }
}

void _recordErrorTelemetry({
  required String loggerName,
  required String spanName,
  required String logBody,
  required Map<String, Object> attributes,
  required Object error,
  required StackTrace? stackTrace,
  required String Function() describe,
}) {
  if (!Otel.isInitialized) {
    return;
  }

  final tracer = Otel.instance.tracerProvider.getTracer(
    loggerName,
    version: '0.0.1-alpha.1',
  );
  final span = tracer.startSpan(
    spanName,
    kind: SpanKind.internal,
    attributes: attributes,
  );
  try {
    _guarded(() => span.recordException(error, stackTrace: stackTrace));
    String? description;
    _guarded(() => description = describe());
    span.setStatus(SpanStatus.error, description: description);
  } finally {
    unawaited(span.end());
  }

  Otel.instance.loggerProvider
      .getLogger(loggerName)
      .error(
        logBody,
        attributes: attributes,
        error: error,
        stackTrace: stackTrace,
      );
}

Map<String, Object> _frameworkErrorAttributes(FlutterErrorDetails details) {
  final exception = details.exception;
  final attributes = <String, Object>{
    'flutter.error.source': 'framework',
    SemanticAttributes.exceptionType: exception.runtimeType.toString(),
    SemanticAttributes.exceptionMessage: exception.toString(),
    'error.group.name': _errorGroupName(
      source: 'framework',
      exception: exception,
      context: details.context?.toDescription(),
    ),
  };

  if (details.library != null) {
    attributes['flutter.error.library'] = details.library!;
  }
  if (details.context != null) {
    attributes['flutter.error.context'] = details.context!.toDescription();
  }

  final diagnostics = _collectDiagnostics(details);
  if (diagnostics != null) {
    attributes['flutter.error.diagnostics'] = diagnostics;
  }

  _applyRouteContext(attributes);
  _applyBreadcrumbs(attributes);

  return attributes;
}

Map<String, Object> _platformErrorAttributes(Object error) {
  final attributes = <String, Object>{
    'flutter.error.source': 'platform_dispatcher',
    SemanticAttributes.exceptionType: error.runtimeType.toString(),
    SemanticAttributes.exceptionMessage: error.toString(),
    'error.group.name': _errorGroupName(
      source: 'platform_dispatcher',
      exception: error,
    ),
  };

  _applyRouteContext(attributes);
  _applyBreadcrumbs(attributes);

  return attributes;
}

void _applyBreadcrumbs(Map<String, Object> attributes) {
  final breadcrumbs = OtelFlutterBreadcrumbs.serialize();
  if (breadcrumbs == null || breadcrumbs.isEmpty) {
    return;
  }

  attributes['flutter.error.breadcrumbs'] = breadcrumbs;
}

void _applyRouteContext(Map<String, Object> attributes) {
  final routeContext = OtelFlutterRouteContext.current;
  if (routeContext.isEmpty) {
    return;
  }

  if (routeContext.routeName != null) {
    attributes['flutter.route.name'] = routeContext.routeName!;
    attributes[SemanticAttributes.flutterRoute] = routeContext.routeName!;
    attributes['screen.name'] = routeContext.routeName!;
  }
  if (routeContext.routeRuntimeType != null) {
    attributes['flutter.route.runtime_type'] = routeContext.routeRuntimeType!;
    attributes['screen.class'] = routeContext.routeRuntimeType!;
  }
  if (routeContext.previousRouteName != null) {
    attributes['flutter.previous_route.name'] = routeContext.previousRouteName!;
    attributes['screen.previous.name'] = routeContext.previousRouteName!;
  }
}

String _errorGroupName({
  required String source,
  required Object exception,
  String? context,
}) {
  final buffer = StringBuffer()
    ..write(source)
    ..write(':')
    ..write(exception.runtimeType);
  if (context != null && context.isNotEmpty) {
    buffer
      ..write(':')
      ..write(context);
  }
  return buffer.toString();
}

String? _collectDiagnostics(FlutterErrorDetails details) {
  final collector = details.informationCollector;
  if (collector == null) {
    return null;
  }

  final diagnostics = collector()
      .map((node) => node.toDescription())
      .where((entry) => entry.isNotEmpty)
      .toList(growable: false);
  if (diagnostics.isEmpty) {
    return null;
  }

  return diagnostics.join(' | ');
}
