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
  });

  /// Exporter used for each collection cycle.
  final MetricExporter exporter;

  /// Interval between automatic collection runs.
  final Duration interval;

  /// Optional timeout applied to each export operation.
  final Duration? exportTimeout;
  MeterProvider? _provider;
  Timer? _timer;
  bool _isShutdown = false;

  /// Completes when the current collect/export cycle ends. Never completes
  /// with an error, so a failed cycle cannot poison the next one.
  Future<void>? _inFlight;

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
  /// waits for it and then runs its own, so at most one export is in
  /// flight per reader.
  Future<void> collect() async {
    final previous = _inFlight;
    final cycle = Completer<void>();
    _inFlight = cycle.future;
    try {
      if (previous != null) {
        await previous;
      }
      await _collectAndExport();
    } finally {
      cycle.complete();
      if (identical(_inFlight, cycle.future)) {
        _inFlight = null;
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
  Future<void> forceFlush() async {
    if (_isShutdown) {
      return;
    }

    await collect();
    await exporter.forceFlush();
  }

  @override
  /// Stops periodic collection and shuts down the exporter.
  Future<void> shutdown() async {
    if (_isShutdown) {
      return;
    }
    _isShutdown = true;
    _timer?.cancel();
    await exporter.shutdown();
  }
}
