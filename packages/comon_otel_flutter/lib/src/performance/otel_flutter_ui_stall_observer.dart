import 'dart:async';

import 'package:comon_otel/comon_otel.dart';
import 'package:flutter/widgets.dart';

import '../comon_otel_flutter_config.dart';
import '../errors/otel_flutter_breadcrumbs.dart';

/// Monotonic elapsed-time source used by the stall poller.
typedef OtelFlutterElapsed = Duration Function();

/// Heuristic observer that detects delayed UI thread ticks.
///
/// The poll timer only runs while the app lifecycle is
/// [AppLifecycleState.resumed]. In any other state (and in headless isolates
/// that never report a lifecycle, such as background workers) it is paused,
/// so a process frozen in the background never shows up as a giant stall.
/// Delays are measured on a monotonic clock, never on wall-clock time.
///
/// Known blind spot (deliberate): [AppLifecycleState.inactive] is also
/// paused. On Android that covers a visible but unfocused app — multi-window
/// / split screen, a system permission dialog, the notification shade pulled
/// down — so UI stalls that happen in those states are not reported. The
/// trade-off favours never emitting false stalls from a suspended process
/// over covering those partially visible states.
final class OtelFlutterUiStallObserver with WidgetsBindingObserver {
  /// Creates a UI stall observer.
  OtelFlutterUiStallObserver({
    this.loggerName = 'comon_otel.flutter',
    this.durationMetricName = 'flutter.ui.stall.duration',
    this.countMetricName = 'flutter.ui.stall.count',
    this.logName = 'flutter.ui_stall',
    this.checkInterval = const Duration(milliseconds: 50),
    this.threshold = const Duration(milliseconds: 100),
    this.staticAttributes = const <String, Object>{},
    OtelFlutterNow? now,
    OtelFlutterElapsed? elapsed,
  }) : _now = now ?? _defaultNow,
       _elapsed = elapsed ?? _stopwatchElapsed();

  static DateTime _defaultNow() => DateTime.now().toUtc();

  static OtelFlutterElapsed _stopwatchElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  /// Logger and meter scope name.
  final String loggerName;

  /// Metric name for stall duration.
  final String durationMetricName;

  /// Metric name for stall count.
  final String countMetricName;

  /// Log body emitted for stall warnings.
  final String logName;

  /// Poll interval used to detect delayed ticks.
  final Duration checkInterval;

  /// Minimum excess delay considered a stall.
  final Duration threshold;

  /// Static attributes merged into every recorded metric (e.g.
  /// `device.tier`). These are the ONLY metric attributes: per-stall values
  /// (delay, threshold, interval) go to the log record, never to a label.
  final Map<String, Object> staticAttributes;
  final OtelFlutterNow _now;
  final OtelFlutterElapsed _elapsed;

  WidgetsBinding? _binding;
  Timer? _timer;
  Duration? _lastTimerTickElapsed;
  DateTime? _lastTickAt;
  Histogram<double>? _durationHistogramCache;
  Counter<int>? _countCounterCache;

  /// Whether the poll timer is currently running.
  bool get isPolling => _timer != null;

  Histogram<double>? get _durationHistogram {
    if (!Otel.isInitialized) {
      return null;
    }

    return _durationHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createHistogram(
          durationMetricName,
          unit: 'ms',
          description: 'Heuristic duration of detected UI thread stalls.',
          boundaries: <double>[50, 100, 250, 500, 1000],
        );
  }

  Counter<int>? get _countCounter {
    if (!Otel.isInitialized) {
      return null;
    }

    return _countCounterCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.0.1-alpha.1')
        .createIntCounter(
          countMetricName,
          description: 'Count of heuristic UI thread stalls.',
        );
  }

  /// Arms stall detection on [binding] (defaults to the current
  /// [WidgetsBinding]). Polling starts right away only if the app is already
  /// resumed; otherwise it starts on the next transition to resumed.
  ///
  /// Polling stops on every non-resumed state, including
  /// [AppLifecycleState.inactive]: stalls while the app is visible but
  /// unfocused (Android multi-window, permission dialog, notification shade)
  /// are intentionally not measured — see the class documentation.
  void start({WidgetsBinding? binding}) {
    if (_binding != null) {
      return;
    }

    final WidgetsBinding resolved;
    try {
      resolved = binding ?? WidgetsBinding.instance;
    } catch (_) {
      // No binding (should not happen under Flutter): never poll blindly.
      return;
    }
    _binding = resolved;
    resolved.addObserver(this);
    _applyLifecycleState(resolved.lifecycleState);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _applyLifecycleState(state);
  }

  void _applyLifecycleState(AppLifecycleState? state) {
    if (state == AppLifecycleState.resumed) {
      _resumePolling();
    } else {
      _pausePolling();
    }
  }

  void _resumePolling() {
    if (_timer != null) {
      return;
    }
    // Fresh baseline: time spent paused is never measured as a stall.
    _lastTimerTickElapsed = _elapsed();
    _timer = Timer.periodic(checkInterval, (_) => _onTimerTick());
  }

  void _pausePolling() {
    _timer?.cancel();
    _timer = null;
    _lastTimerTickElapsed = null;
  }

  void _onTimerTick() {
    final now = _elapsed();
    final last = _lastTimerTickElapsed;
    _lastTimerTickElapsed = now;
    if (last == null) {
      return;
    }
    _recordObservedDelay(now - last - checkInterval);
  }

  /// Stops polling, detaches from the binding and clears internal state.
  void dispose() {
    _binding?.removeObserver(this);
    _binding = null;
    _pausePolling();
    _lastTickAt = null;
  }

  /// Records one scheduler tick for stall detection (manual feed; the
  /// built-in poller does not go through here).
  void recordTick([DateTime? timestamp]) {
    final now = timestamp ?? _now();
    final lastTickAt = _lastTickAt;
    _lastTickAt = now;

    if (lastTickAt == null) {
      return;
    }

    _recordObservedDelay(now.difference(lastTickAt) - checkInterval);
  }

  void _recordObservedDelay(Duration observedDelay) {
    if (!Otel.isInitialized || observedDelay < threshold) {
      return;
    }

    final delayMs = observedDelay.inMicroseconds / 1000;
    final detailAttributes = <String, Object>{
      ...staticAttributes,
      'flutter.ui_stall.delay_ms': delayMs,
      'flutter.ui_stall.threshold_ms': threshold.inMicroseconds / 1000,
      'flutter.ui_stall.check_interval_ms': checkInterval.inMicroseconds / 1000,
    };

    OtelFlutterBreadcrumbs.add(
      category: 'performance',
      message: 'ui_stall',
      attributes: detailAttributes,
    );

    _durationHistogram?.record(delayMs, attributes: staticAttributes);
    _countCounter?.add(1, attributes: staticAttributes);
    Otel.instance.loggerProvider
        .getLogger(loggerName)
        .warn(logName, attributes: detailAttributes);
  }
}
