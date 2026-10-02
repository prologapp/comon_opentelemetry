import 'dart:async';

import '../exporters/metric_exporter.dart';
import 'meter_provider.dart';
import 'metric_reader.dart';

/// Metric reader that periodically exports collected metrics.
final class PeriodicMetricReader implements MetricReader {
  /// Creates a periodic metric reader.
  PeriodicMetricReader({
    required this.exporter,
    this.interval = const Duration(seconds: 60),
    this.exportTimeout,
    this.inFlightWaitLimit = const Duration(seconds: 2),
  });

  /// Exporter used for each collection cycle.
  final MetricExporter exporter;

  /// Interval between automatic collection runs.
  final Duration interval;

  /// Optional timeout applied to each export operation.
  final Duration? exportTimeout;

  /// Longest time [forceFlush] and [shutdown] wait for an export that is
  /// already in flight (e.g. a timer cycle stuck on a slow network) before
  /// going on. Keeps a flush on app pause from blocking for the whole
  /// export timeout and retry chain.
  final Duration inFlightWaitLimit;
  MeterProvider? _provider;
  Timer? _timer;
  bool _isShutdown = false;

  /// Completes when the current collect/export cycle ends. Never completes
  /// with an error, so a failed cycle cannot poison the next one.
  Future<void>? _inFlight;

  /// Number of exports currently running (at most 2: a stuck cycle plus the
  /// one a bounded [forceFlush] starts alongside it).
  int _exportsRunning = 0;

  @override
  /// Attaches this reader to a provider and starts periodic collection.
  void attach(MeterProvider provider) {
    _provider = provider;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) {
      // A tick that lands while an export is still running is skipped:
      // temporality is cumulative, so the next cycle carries the data, and
      // queueing ticks behind a slow export would grow without bound.
      if (_inFlight != null) {
        return;
      }
      unawaited(_collectFromTimer());
    });
  }

  /// Timer-driven collection: nobody awaits it, so any failure (exporter
  /// throwing, export timeout) is swallowed instead of surfacing as an
  /// unhandled error every interval.
  Future<void> _collectFromTimer() async {
    try {
      await collect();
    } catch (_) {
      // Telemetry never throws into the host.
    }
  }

  @override
  /// Collects metrics from the attached provider and exports them.
  ///
  /// Cycles are serialized: a call made while another cycle is running
  /// waits for it and then runs its own. The only exception is
  /// [forceFlush], which after [inFlightWaitLimit] may run one export
  /// alongside a stuck one.
  Future<void> collect() => _runCycle(after: _inFlight);

  /// Runs one collect/export cycle, registered as the in-flight cycle so
  /// timer ticks skip and later [collect] calls queue behind it. When
  /// [after] is given, the export starts only once that cycle has ended.
  Future<void> _runCycle({Future<void>? after}) async {
    final cycle = Completer<void>();
    _inFlight = cycle.future;
    try {
      if (after != null) {
        await after;
      }
      _exportsRunning += 1;
      try {
        await _collectAndExport();
      } finally {
        _exportsRunning -= 1;
      }
    } finally {
      cycle.complete();
      if (identical(_inFlight, cycle.future)) {
        _inFlight = null;
      }
    }
  }

  /// Waits, for at most [inFlightWaitLimit] in total, until no cycle is in
  /// flight (cycles started meanwhile, e.g. by a concurrent [forceFlush],
  /// are waited for too). The result is already stale when the caller
  /// resumes, so it must not be used to decide whether to start a cycle
  /// (see [forceFlush]); [shutdown] only uses it to wait.
  Future<void> _waitForIdle() async {
    final elapsed = Stopwatch()..start();
    while (true) {
      final inFlight = _inFlight;
      if (inFlight == null) {
        return;
      }
      final remaining = inFlightWaitLimit - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        return;
      }
      try {
        await inFlight.timeout(remaining);
      } on TimeoutException {
        return;
      }
    }
  }

  Future<void> _collectAndExport() async {
    if (_isShutdown) {
      return;
    }

    final provider = _provider;
    if (provider == null) {
      throw StateError(
        'PeriodicMetricReader is not attached to a MeterProvider.',
      );
    }

    final metrics = provider.collectAll();
    if (metrics.isEmpty) {
      return;
    }

    final exportFuture = exporter.export(metrics);
    if (exportTimeout == null) {
      await exportFuture;
    } else {
      await exportFuture.timeout(exportTimeout!);
    }
  }

  @override
  /// Triggers one collection cycle and flushes the exporter.
  ///
  /// Waits for an export already in flight for at most
  /// [inFlightWaitLimit], then runs its own export of fresh data even if
  /// that one is still running (so at most one extra export runs in
  /// parallel; with two already running it skips its own, since temporality
  /// is cumulative and the running cycles carry the data).
  Future<void> forceFlush() async {
    if (_isShutdown) {
      return;
    }

    final elapsed = Stopwatch()..start();
    while (true) {
      // The idle check and the start of the cycle (which registers itself
      // as in flight synchronously) happen in the same synchronous step
      // after each await, so concurrent callers that find the reader idle
      // still run one after the other.
      final inFlight = _inFlight;
      if (inFlight == null) {
        await _runCycle();
        break;
      }
      final remaining = inFlightWaitLimit - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        // Still stuck after the limit: export alongside it, unless two
        // exports are already running.
        if (_exportsRunning < 2) {
          await _runCycle();
        }
        break;
      }
      try {
        await inFlight.timeout(remaining);
      } on TimeoutException {
        // Re-checked at the top of the loop.
      }
    }
    await exporter.forceFlush();
  }

  @override
  /// Stops periodic collection and shuts down the exporter.
  ///
  /// An export already in flight gets up to [inFlightWaitLimit] to finish
  /// before the exporter is shut down, so the last batch is not cut off;
  /// no new cycle starts once shutdown begins.
  Future<void> shutdown() async {
    if (_isShutdown) {
      return;
    }
    _isShutdown = true;
    _timer?.cancel();
    await _waitForIdle();
    await exporter.shutdown();
  }
}
