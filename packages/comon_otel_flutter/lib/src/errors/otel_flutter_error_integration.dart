import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/foundation.dart';

import '../comon_otel_flutter_instrumentation.dart';
import '../navigation/otel_flutter_route_context.dart';
import 'otel_flutter_breadcrumbs.dart';
import 'otel_flutter_error_hooks.dart';

/// Captures a framework error and forwards it into OpenTelemetry.
void recordFlutterFrameworkError(
  FlutterErrorDetails details, {
  String loggerName = 'comon_otel.flutter',
  FlutterExceptionHandler? fallback,
}) {
  final attributes = _frameworkErrorAttributes(details);
  OtelFlutterErrorHooks.dispatchFrameworkError(
    OtelFlutterErrorSnapshot(
      source: 'framework',
      error: details.exception,
      stackTrace: details.stack,
      attributes: Map<String, Object>.unmodifiable(attributes),
      breadcrumbs: OtelFlutterBreadcrumbs.snapshot(),
    ),
  );

  if (Otel.isInitialized) {
    final logger = Otel.instance.loggerProvider.getLogger(loggerName);
    final tracer = Otel.instance.tracerProvider.getTracer(
      loggerName,
      version: '0.0.1-alpha.1',
    );
    final span = tracer.startSpan(
      'flutter.error',
      kind: SpanKind.internal,
      attributes: attributes,
    );
    span.recordException(details.exception, stackTrace: details.stack);
    span.setStatus(SpanStatus.error, description: details.exceptionAsString());
    unawaited(span.end());

    logger.error(
      'flutter.framework_error',
      attributes: attributes,
      error: details.exception,
      stackTrace: details.stack,
    );
  }

  if (fallback != null) {
    fallback(details);
    return;
  }

  FlutterError.presentError(details);
}

/// Captures a platform dispatcher error and forwards it into OpenTelemetry.
bool recordFlutterPlatformError(
  Object error,
  StackTrace stackTrace, {
  String loggerName = 'comon_otel.flutter',
  OtelPlatformErrorCallback? fallback,
}) {
  final attributes = _platformErrorAttributes(error);
  OtelFlutterErrorHooks.dispatchPlatformError(
    OtelFlutterErrorSnapshot(
      source: 'platform_dispatcher',
      error: error,
      stackTrace: stackTrace,
      attributes: Map<String, Object>.unmodifiable(attributes),
      breadcrumbs: OtelFlutterBreadcrumbs.snapshot(),
    ),
  );

  if (Otel.isInitialized) {
    final logger = Otel.instance.loggerProvider.getLogger(loggerName);
    final tracer = Otel.instance.tracerProvider.getTracer(
      loggerName,
      version: '0.0.1-alpha.1',
    );
    final span = tracer.startSpan(
      'flutter.platform_error',
      kind: SpanKind.internal,
      attributes: attributes,
    );
    span.recordException(error, stackTrace: stackTrace);
    span.setStatus(SpanStatus.error, description: error.toString());
    unawaited(span.end());

    logger.error(
      'flutter.platform_error',
      attributes: attributes,
      error: error,
      stackTrace: stackTrace,
    );
  }

  // Recording telemetry does not handle the error: only the fallback (e.g.
  // Sentry or the app's own handler) can claim it. Without one, return false
  // so the engine keeps its default reporting.
  return fallback?.call(error, stackTrace) ?? false;
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
