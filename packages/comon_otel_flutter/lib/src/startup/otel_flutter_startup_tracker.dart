import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/widgets.dart';

/// Tracks app startup, first frame, and first interaction milestones.
final class OtelFlutterStartupTracker {
  /// Internal constructor for a startup tracker.
  OtelFlutterStartupTracker._({
    required this.loggerName,
    required this.spanName,
    required this.firstFrameEventName,
    required this.firstInteractionLogName,
    required Span startupSpan,
    required bool markFirstFrame,
    required Map<String, Object> staticMetricAttributes,
  }) : _startupSpan = startupSpan,
       _markFirstFrame = markFirstFrame,
       _staticMetricAttributes = staticMetricAttributes;

  /// Metric name for the per-phase startup duration histogram.
  static const String phaseDurationMetricName = 'app.startup.phase.duration';

  /// Attribute key used to label the phase on span and histogram.
  static const String phaseAttribute = 'app.startup.phase';

  final String loggerName;
  final String spanName;
  final String firstFrameEventName;
  final String firstInteractionLogName;
  final Span _startupSpan;
  final bool _markFirstFrame;
  final Map<String, Object> _staticMetricAttributes;

  bool _startupCompleted = false;
  bool _firstInteractionMarked = false;
  Histogram<double>? _phaseDurationHistogramCache;

  /// Starts startup tracking when the SDK has already been initialized.
  static OtelFlutterStartupTracker? start({
    required WidgetsBinding binding,
    required String loggerName,
    required String spanName,
    required String firstFrameEventName,
    required String firstInteractionLogName,
    required bool markFirstFrame,
    DateTime? startTime,
    Map<String, Object>? appStartupAttributes,
    Map<String, Object> staticMetricAttributes = const <String, Object>{},
  }) {
    if (!Otel.isInitialized) {
      return null;
    }

    final tracer = Otel.instance.tracerProvider.getTracer(
      loggerName,
      version: '0.1.0',
    );
    final startupSpan = tracer.startSpan(
      spanName,
      kind: SpanKind.internal,
      startTime: startTime,
      attributes: <String, Object>{
        'flutter.startup.completed': false,
        ...?appStartupAttributes,
      },
    );

    final tracker = OtelFlutterStartupTracker._(
      loggerName: loggerName,
      spanName: spanName,
      firstFrameEventName: firstFrameEventName,
      firstInteractionLogName: firstInteractionLogName,
      startupSpan: startupSpan,
      markFirstFrame: markFirstFrame,
      staticMetricAttributes: staticMetricAttributes,
    );

    if (markFirstFrame) {
      binding.addPostFrameCallback((_) {
        unawaited(tracker.completeStartup());
      });
    }

    return tracker;
  }

  /// Sets an attribute on the root startup span, e.g. `launch.source`
  /// derived after startup has already begun. No-op once the root span has
  /// ended (via [completeStartup]) or when Otel was never initialized.
  void setStartupAttribute(String key, Object value) {
    try {
      _startupSpan.setAttribute(key, value);
    } catch (_) {
      // Telemetry never breaks the host.
    }
  }

  Histogram<double>? get _phaseDurationHistogram {
    if (!Otel.isInitialized) {
      return null;
    }

    return _phaseDurationHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createHistogram(
          phaseDurationMetricName,
          unit: 'ms',
          description: 'Duration of a named app startup phase.',
          boundaries: const <double>[50, 100, 250, 500, 1000, 2500, 5000],
        );
  }

  /// Starts a child span for a named startup phase (`<spanName>.<phase>`).
  ///
  /// Returns `null` when Otel is not initialized or when the root startup
  /// span has already ended (post [completeStartup]) — at that point the
  /// phase span would be a tracing anti-pattern (child created under an
  /// already-closed parent), so it is skipped; [trackPhase] still records
  /// the phase duration histogram regardless.
  Span? startPhase(String phase) {
    if (!Otel.isInitialized || _startupCompleted) {
      return null;
    }

    try {
      final tracer = Otel.instance.tracerProvider.getTracer(
        loggerName,
        version: '0.1.0',
      );
      return tracer.startSpan(
        '$spanName.$phase',
        kind: SpanKind.internal,
        parent: _startupSpan,
        attributes: <String, Object>{phaseAttribute: phase},
      );
    } catch (_) {
      return null;
    }
  }

  /// Runs [body] inside a startup phase span and records its duration in the
  /// `app.startup.phase.duration` histogram (labeled with [phaseAttribute]
  /// plus any configured static metric attributes) — even when no span was
  /// created (Otel uninitialized or root already ended). If [body] throws,
  /// the span (when present) records the exception and an error status, the
  /// histogram still records, and the original error is rethrown to the
  /// host unchanged: telemetry never breaks the host.
  Future<T> trackPhase<T>(String phase, Future<T> Function() body) async {
    final span = startPhase(phase);
    final stopwatch = Stopwatch()..start();

    try {
      final result = await body();
      stopwatch.stop();
      _recordPhaseDuration(phase, stopwatch);
      _endPhaseSpan(span, isError: false);
      return result;
    } catch (error, stackTrace) {
      stopwatch.stop();
      _recordPhaseDuration(phase, stopwatch);
      _endPhaseSpan(span, isError: true, error: error, stackTrace: stackTrace);
      rethrow;
    }
  }

  void _recordPhaseDuration(String phase, Stopwatch stopwatch) {
    _recordPhaseDurationMs(phase, stopwatch.elapsedMicroseconds / 1000);
  }

  void _recordPhaseDurationMs(String phase, double durationMs) {
    try {
      _phaseDurationHistogram?.record(
        durationMs,
        attributes: <String, Object>{
          ..._staticMetricAttributes,
          phaseAttribute: phase,
        },
      );
    } catch (_) {
      // Telemetry never breaks the host.
    }
  }

  /// Records a startup phase that already ran to completion before the
  /// tracker existed (e.g. DI/remote-config/migrations/auth-restore that
  /// finish before [ComonOtelFlutter.install] runs). Same semantics as
  /// [trackPhase]: creates a child span of the root startup span named
  /// `<spanName>.<phase>` with explicit [start]/[end] times and the
  /// [phaseAttribute], ends it immediately, and records `(end - start)` in
  /// milliseconds into the `app.startup.phase.duration` histogram (labeled
  /// with [phaseAttribute] plus any configured static metric attributes).
  ///
  /// If [end] is before [start] the recorded duration is clamped to zero
  /// (still recorded — a bad clock read shouldn't silently drop the sample).
  /// No span is created once the root startup span has already ended (post
  /// [completeStartup]) or when Otel was never initialized, matching
  /// [startPhase]; the histogram still records in both cases. Telemetry
  /// failures are swallowed and never reach the host.
  void recordCompletedPhase(
    String phase, {
    required DateTime start,
    required DateTime end,
  }) {
    final durationMs = end.isBefore(start)
        ? 0.0
        : end.difference(start).inMicroseconds / 1000;

    if (Otel.isInitialized && !_startupCompleted) {
      try {
        final tracer = Otel.instance.tracerProvider.getTracer(
          loggerName,
          version: '0.1.0',
        );
        final span = tracer.startSpan(
          '$spanName.$phase',
          kind: SpanKind.internal,
          parent: _startupSpan,
          startTime: start,
          attributes: <String, Object>{phaseAttribute: phase},
        );
        span.setStatus(SpanStatus.ok);
        unawaited(span.end(endTime: end));
      } catch (_) {
        // Telemetry never breaks the host.
      }
    }

    _recordPhaseDurationMs(phase, durationMs);
  }

  void _endPhaseSpan(
    Span? span, {
    required bool isError,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (span == null) {
      return;
    }

    try {
      if (isError) {
        span.recordException(error!, stackTrace: stackTrace);
        span.setStatus(SpanStatus.error, description: error.toString());
      } else {
        span.setStatus(SpanStatus.ok);
      }
      unawaited(span.end());
    } catch (_) {
      // Telemetry never breaks the host.
    }
  }

  /// Completes the startup span; when tracking the first frame, also emits
  /// the first-frame event and the `app.first_frame` log.
  Future<void> completeStartup() async {
    if (_startupCompleted) {
      return;
    }

    _startupCompleted = true;
    if (_markFirstFrame) {
      _startupSpan.addEvent(firstFrameEventName);
    }
    _startupSpan.setAttribute('flutter.startup.completed', true);
    await _startupSpan.end();

    // Only a tracker closed by the first frame may claim a first-frame
    // marker; with markFirstFrame:false the host closes startup at an
    // arbitrary later point, which is not a first frame.
    if (_markFirstFrame && Otel.isInitialized) {
      Otel.instance.loggerProvider
          .getLogger(loggerName)
          .info(
            'app.first_frame',
            attributes: const <String, Object>{
              'flutter.startup.completed': true,
            },
          );
    }
  }

  /// Marks the first meaningful user interaction.
  void markFirstInteraction({Map<String, Object>? attributes}) {
    if (_firstInteractionMarked || !Otel.isInitialized) {
      return;
    }

    _firstInteractionMarked = true;
    Otel.instance.loggerProvider
        .getLogger(loggerName)
        .info(
          firstInteractionLogName,
          attributes: <String, Object>{
            'flutter.interaction.first': true,
            ...?attributes,
          },
        );
  }

  /// Completes startup if it has not already finished.
  void dispose() {
    if (!_startupCompleted) {
      unawaited(completeStartup());
    }
  }
}
