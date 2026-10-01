import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/widgets.dart';

import '../comon_otel_flutter_config.dart';
import '../errors/otel_flutter_breadcrumbs.dart';

/// Widgets binding observer that records lifecycle events and metrics.
final class OtelFlutterBindingObserver with WidgetsBindingObserver {
  /// Creates a lifecycle observer.
  OtelFlutterBindingObserver({
    this.loggerName = 'comon_otel.flutter',
    this.logLifecycleTransitions = true,
    this.trackLifecycleDurations = true,
    this.trackMemoryPressureMetrics = true,
    this.foregroundDurationMetricName = 'app.foreground.duration',
    this.backgroundDurationMetricName = 'app.background.duration',
    this.memoryPressureCountMetricName = 'app.memory_pressure.count',
    OtelFlutterNow? now,
  }) : _now = now ?? _defaultNow;

  static DateTime _defaultNow() => DateTime.now().toUtc();

  final OtelFlutterNow _now;

  /// Logger and meter scope name.
  final String loggerName;

  /// Whether to emit lifecycle transition logs.
  final bool logLifecycleTransitions;

  /// Whether to record foreground and background durations.
  final bool trackLifecycleDurations;

  /// Whether to count memory pressure callbacks.
  final bool trackMemoryPressureMetrics;

  /// Metric name for foreground duration.
  final String foregroundDurationMetricName;

  /// Metric name for background duration.
  final String backgroundDurationMetricName;

  /// Metric name for memory pressure count.
  final String memoryPressureCountMetricName;

  AppLifecycleState? _lastLifecycleState;
  DateTime? _foregroundStartedAt;
  DateTime? _backgroundStartedAt;
  Histogram<double>? _foregroundHistogramCache;
  Histogram<double>? _backgroundHistogramCache;
  Counter<int>? _memoryPressureCounterCache;

  Histogram<double>? get _foregroundHistogram {
    if (!Otel.isInitialized || !trackLifecycleDurations) {
      return null;
    }

    return _foregroundHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createHistogram(
          foregroundDurationMetricName,
          unit: 'ms',
          description:
              'Time spent in the foreground between lifecycle transitions.',
        );
  }

  Histogram<double>? get _backgroundHistogram {
    if (!Otel.isInitialized || !trackLifecycleDurations) {
      return null;
    }

    return _backgroundHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createHistogram(
          backgroundDurationMetricName,
          unit: 'ms',
          description:
              'Time spent outside the foreground between lifecycle transitions.',
        );
  }

  Counter<int>? get _memoryPressureCounter {
    if (!Otel.isInitialized || !trackMemoryPressureMetrics) {
      return null;
    }

    return _memoryPressureCounterCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createIntCounter(
          memoryPressureCountMetricName,
          description: 'Count of Flutter memory pressure callbacks.',
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    OtelFlutterBreadcrumbs.add(
      category: 'lifecycle',
      message: state.name,
      attributes: <String, Object>{'flutter.lifecycle.state': state.name},
    );

    if (Otel.isInitialized) {
      _recordLifecycleDurations(state);

      if (logLifecycleTransitions) {
        Otel.instance.loggerProvider
            .getLogger(loggerName)
            .info(
              'app.lifecycle',
              attributes: <String, Object>{
                SemanticAttributes.appLifecycleState: state.name,
                'flutter.lifecycle.state': state.name,
              },
            );
      }
    }

    if (Otel.isInitialized && _isBackgrounding(state)) {
      // The only reliable point to drain the in-memory queue before the OS
      // suspends or kills the process. A failed flush must never reach
      // PlatformDispatcher.onError as an unhandled async error.
      unawaited(Otel.forceFlush().catchError((Object _) {}));
    }

    _lastLifecycleState = state;
  }

  // `hidden` is left out on purpose: leaving the app goes
  // inactive -> hidden -> paused, so flushing on both hidden and paused
  // drained the queues twice per trip to the background.
  bool _isBackgrounding(AppLifecycleState state) {
    return state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
  }

  @override
  void didHaveMemoryPressure() {
    if (!Otel.isInitialized) {
      return;
    }

    OtelFlutterBreadcrumbs.add(
      category: 'lifecycle',
      message: 'memory_pressure',
    );

    _memoryPressureCounter?.add(1);

    Otel.instance.loggerProvider
        .getLogger(loggerName)
        .warn('app.memory_pressure');
  }

  void _recordLifecycleDurations(AppLifecycleState state) {
    final now = _now();
    final wasForeground = _isForeground(_lastLifecycleState);
    final isForeground = _isForeground(state);

    if (_lastLifecycleState == null) {
      if (isForeground) {
        _foregroundStartedAt = now;
      } else {
        _backgroundStartedAt = now;
      }
      return;
    }

    if (wasForeground && !isForeground) {
      final foregroundStartedAt = _foregroundStartedAt;
      if (foregroundStartedAt != null) {
        _foregroundHistogram?.record(
          now.difference(foregroundStartedAt).inMicroseconds / 1000,
          attributes: <String, Object>{
            'app.lifecycle.from': _lastLifecycleState!.name,
            'app.lifecycle.to': state.name,
          },
        );
      }
      _foregroundStartedAt = null;
      _backgroundStartedAt = now;
      return;
    }

    if (!wasForeground && isForeground) {
      final backgroundStartedAt = _backgroundStartedAt;
      if (backgroundStartedAt != null) {
        _backgroundHistogram?.record(
          now.difference(backgroundStartedAt).inMicroseconds / 1000,
          attributes: <String, Object>{
            'app.lifecycle.from': _lastLifecycleState!.name,
            'app.lifecycle.to': state.name,
          },
        );
      }
      _backgroundStartedAt = null;
      _foregroundStartedAt = now;
    }
  }

  bool _isForeground(AppLifecycleState? state) {
    return state == AppLifecycleState.resumed;
  }
}
