import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/foundation.dart';

import '../comon_otel_flutter_instrumentation.dart';
import '../navigation/otel_flutter_route_context.dart';
import 'otel_flutter_breadcrumbs.dart';
import 'otel_flutter_error_hooks.dart';
import 'otel_flutter_error_rate_limiter.dart';

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
  _guarded(() {
    _captureError(
      loggerName: loggerName,
      source: 'framework',
      spanName: 'flutter.error',
      logBody: 'flutter.framework_error',
      error: details.exception,
      stackTrace: details.stack,
      groupName: () => _errorGroupName(
        source: 'framework',
        exception: details.exception,
        context: details.context?.toDescription(),
      ),
      buildAttributes: (group) => _frameworkErrorAttributes(details, group),
      hasHook: OtelFlutterErrorHooks.hasFrameworkErrorListener,
      dispatchHook: OtelFlutterErrorHooks.dispatchFrameworkError,
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
  _guarded(() {
    _captureError(
      loggerName: loggerName,
      source: 'platform_dispatcher',
      spanName: 'flutter.platform_error',
      logBody: 'flutter.platform_error',
      error: error,
      stackTrace: stackTrace,
      groupName: () =>
          _errorGroupName(source: 'platform_dispatcher', exception: error),
      buildAttributes: (group) => _platformErrorAttributes(error, group),
      hasHook: OtelFlutterErrorHooks.hasPlatformErrorListener,
      dispatchHook: OtelFlutterErrorHooks.dispatchPlatformError,
      describe: error.toString,
    );
  });

  // Recording telemetry does not handle the error: only the fallback (e.g.
  // Sentry or the app's own handler) can claim it. Without one, return false
  // so the engine keeps its default reporting.
  return fallback?.call(error, stackTrace) ?? false;
}

/// Decide o limitador antes de montar os atributos: a montagem (toString,
/// diagnostics, breadcrumbs, scrub de cada string) é a parte cara, e um erro
/// em loop pagaria por ela em toda ocorrência suprimida.
///
/// O grupo sai só de fonte, tipo e contexto ([groupName]), sem toString. Os
/// atributos completos só são montados quando a ocorrência vai ser exportada
/// ou quando há hook configurado para a fonte (o snapshot do hook carrega os
/// atributos, e o hook roda em toda ocorrência).
void _captureError({
  required String loggerName,
  required String source,
  required String spanName,
  required String logBody,
  required Object error,
  required StackTrace? stackTrace,
  required String Function() groupName,
  required Map<String, Object> Function(String group) buildAttributes,
  required bool hasHook,
  required void Function(OtelFlutterErrorSnapshot snapshot) dispatchHook,
  required String Function() describe,
}) {
  final group = _guardedGroupName(groupName, source: source, error: error);

  var export = false;
  _guarded(() {
    // Sem SDK não há o que exportar: não consome cota do grupo.
    if (!Otel.isInitialized) {
      return;
    }
    export = OtelFlutterErrorRateLimiter.tryAcquire(group);
    if (!export) {
      _countSuppressed(loggerName, source);
    }
  });

  if (!export && !hasHook) {
    return;
  }

  final attributes = _guardedAttributes(
    () => buildAttributes(group),
    source: source,
    error: error,
  );
  if (hasHook) {
    _guarded(() {
      dispatchHook(
        OtelFlutterErrorSnapshot(
          source: source,
          error: error,
          stackTrace: stackTrace,
          attributes: Map<String, Object>.unmodifiable(attributes),
          breadcrumbs: OtelFlutterBreadcrumbs.snapshot(),
        ),
      );
    });
  }
  if (export) {
    _guarded(() {
      _recordErrorTelemetry(
        loggerName: loggerName,
        spanName: spanName,
        logBody: logBody,
        attributes: attributes,
        error: error,
        stackTrace: stackTrace,
        describe: describe,
      );
    });
  }
}

/// Nome do grupo do erro com as URLs reduzidas a esquema e host (o mesmo
/// valor exportado em `error.group.name`). Se montá-lo lançar, cai em
/// `<source>:<tipo>`.
String _guardedGroupName(
  String Function() build, {
  required String source,
  required Object error,
}) {
  try {
    return scrubUrls(build());
  } catch (_) {
    return '$source:${error.runtimeType}';
  }
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
///
/// Every string value has its URLs reduced to scheme and host
/// ([scrubUrls]): the exception message, context, diagnostics (e.g.
/// `NetworkImage("<url>")`), breadcrumbs and group name may all embed a full
/// URL with PII in the path or a signature in the query.
Map<String, Object> _guardedAttributes(
  Map<String, Object> Function() build, {
  required String source,
  required Object error,
}) {
  try {
    return <String, Object>{
      for (final entry in build().entries)
        entry.key: switch (entry.value) {
          final String text => scrubUrls(text),
          final value => value,
        },
    };
  } catch (_) {
    return <String, Object>{
      'flutter.error.source': source,
      SemanticAttributes.exceptionType: error.runtimeType.toString(),
    };
  }
}

/// Name of the counter of error occurrences not exported because their
/// group exceeded [OtelFlutterErrorRateLimiter.maxPerMinute].
const String _suppressedCountMetricName = 'flutter.error.suppressed.count';

Otel? _suppressedCounterOwner;
Counter<int>? _suppressedCounter;

/// Counts one suppressed occurrence, labeled only with the closed-set
/// `flutter.error.source` (never the high-cardinality group name).
void _countSuppressed(String loggerName, String source) {
  final otel = Otel.instance;
  if (!identical(otel, _suppressedCounterOwner)) {
    _suppressedCounterOwner = otel;
    _suppressedCounter = otel.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createIntCounter(
          _suppressedCountMetricName,
          description:
              'Captured errors not exported as span and log because their '
              'error.group.name exceeded the per-minute limit.',
        );
  }
  _suppressedCounter!.add(
    1,
    attributes: <String, Object>{'flutter.error.source': source},
  );
}

/// Exporta o span e o log de uma ocorrência já liberada pelo limitador.
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

Map<String, Object> _frameworkErrorAttributes(
  FlutterErrorDetails details,
  String group,
) {
  final exception = details.exception;
  final attributes = <String, Object>{
    'flutter.error.source': 'framework',
    SemanticAttributes.exceptionType: exception.runtimeType.toString(),
    SemanticAttributes.exceptionMessage: exception.toString(),
    'error.group.name': group,
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

Map<String, Object> _platformErrorAttributes(Object error, String group) {
  final attributes = <String, Object>{
    'flutter.error.source': 'platform_dispatcher',
    SemanticAttributes.exceptionType: error.runtimeType.toString(),
    SemanticAttributes.exceptionMessage: error.toString(),
    'error.group.name': group,
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
