import 'dart:async';
import 'dart:io';

import 'package:battery_plus/battery_plus.dart';
import 'package:comon_otel/comon_otel.dart';

import 'otel_flutter_resource_types.dart';

/// Reads the current battery level (0-100), pure Dart seam so tests never
/// touch `battery_plus`.
typedef BatteryLevelGetter = Future<int> Function();

/// Streams already-mapped battery state strings: `charging`/`discharging`/
/// `full`. Pure Dart seam so tests never touch `battery_plus`.
typedef BatteryStateStreamGetter = Stream<String> Function();

String? _mapBatteryState(BatteryState state) {
  switch (state) {
    case BatteryState.charging:
      return 'charging';
    case BatteryState.full:
      return 'full';
    case BatteryState.discharging:
    case BatteryState.connectedNotCharging:
      return 'discharging';
    case BatteryState.unknown:
      return null;
  }
}

Future<int> _defaultBatteryLevelGetter() => Battery().batteryLevel;

Stream<String> _defaultBatteryStateStreamGetter() {
  return Battery().onBatteryStateChanged
      .map(_mapBatteryState)
      .where((state) => state != null)
      .cast<String>();
}

/// Observer that records device-resource metrics: free storage milestones,
/// battery level/state, thermal state transitions, and process RSS.
///
/// Each signal is independently toggled — a disabled signal never creates
/// its instrument, never reads its injected getter, and never subscribes to
/// its stream (no listener registration cost when off).
final class OtelFlutterResourceObserver {
  /// Creates a device resource observer.
  OtelFlutterResourceObserver({
    this.loggerName = 'comon_otel.flutter',
    this.trackStorageMetrics = false,
    this.trackBatteryMetrics = false,
    this.trackThermalMetrics = false,
    this.trackRssMetrics = false,
    this.storageFreeMetricName = 'app.device.storage.free',
    this.batteryLevelMetricName = 'app.device.battery.level',
    this.batteryStateMetricName = 'app.device.battery.state',
    this.thermalCountMetricName = 'app.device.thermal.count',
    this.processRssMetricName = 'app.process.memory.rss',
    this.staticAttributes = const <String, Object>{},
    this.storageFreeBytesGetter,
    this.thermalStateStreamGetter,
    // Test-only seams: production callers never pass these, so the default
    // wiring always goes through battery_plus.
    BatteryLevelGetter? batteryLevelGetter,
    BatteryStateStreamGetter? batteryStateStreamGetter,
  }) : _batteryLevelGetter = batteryLevelGetter ?? _defaultBatteryLevelGetter,
       _batteryStateStreamGetter =
           batteryStateStreamGetter ?? _defaultBatteryStateStreamGetter;

  /// Logger and meter scope name.
  final String loggerName;

  /// Whether to record free storage milestone gauges.
  final bool trackStorageMetrics;

  /// Whether to record battery level/state metrics.
  final bool trackBatteryMetrics;

  /// Whether to count thermal state transitions (the first reading is the
  /// baseline and is not counted).
  final bool trackThermalMetrics;

  /// Whether to record the process RSS gauge.
  final bool trackRssMetrics;

  /// Metric name for the free storage milestone gauge.
  final String storageFreeMetricName;

  /// Metric name for the battery level histogram.
  final String batteryLevelMetricName;

  /// Metric name for the battery state gauge.
  final String batteryStateMetricName;

  /// Metric name for the thermal state transition counter.
  final String thermalCountMetricName;

  /// Metric name for the process RSS gauge.
  final String processRssMetricName;

  /// Static attributes merged into every recorded metric.
  final Map<String, Object> staticAttributes;

  /// Injected reader for current free storage bytes.
  final StorageFreeBytesGetter? storageFreeBytesGetter;

  /// Injected stream of already-mapped thermal state strings.
  final ThermalStateStreamGetter? thermalStateStreamGetter;

  final BatteryLevelGetter _batteryLevelGetter;
  final BatteryStateStreamGetter _batteryStateStreamGetter;

  final Map<String, int> _storageMilestoneBytes = <String, int>{};
  String? _batteryState;
  String? _lastThermalState;
  StreamSubscription<String>? _thermalSubscription;
  StreamSubscription<String>? _batteryStateSubscription;

  /// Set by [dispose], cleared by [start]. The core SDK has no way to
  /// unregister an observable instrument, so a disposed observer keeps its
  /// gauges registered but makes their callbacks observe nothing; the meter
  /// provider drops point-less metrics, so a reinstall never exports the
  /// same series twice.
  bool _disposed = false;

  ObservableGauge<double>? _storageGaugeCache;
  Histogram<double>? _batteryLevelHistogramCache;
  ObservableGauge<double>? _batteryStateGaugeCache;
  Counter<int>? _thermalCounterCache;
  ObservableGauge<double>? _rssGaugeCache;

  ObservableGauge<double>? get _storageGauge {
    if (!Otel.isInitialized || !trackStorageMetrics) {
      return null;
    }

    return _storageGaugeCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createObservableGauge(
          storageFreeMetricName,
          unit: 'By',
          description: 'Free storage bytes at recorded milestones.',
          callback: (result) {
            if (_disposed) {
              return;
            }
            for (final entry in _storageMilestoneBytes.entries) {
              result.observe(
                entry.value.toDouble(),
                attributes: <String, Object>{
                  ...staticAttributes,
                  'milestone': entry.key,
                },
              );
            }
          },
        );
  }

  Histogram<double>? get _batteryLevelHistogram {
    if (!Otel.isInitialized || !trackBatteryMetrics) {
      return null;
    }

    return _batteryLevelHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createHistogram(
          batteryLevelMetricName,
          unit: '%',
          description: 'Battery level (0-100) sampled at recorded moments.',
        );
  }

  ObservableGauge<double>? get _batteryStateGauge {
    if (!Otel.isInitialized || !trackBatteryMetrics) {
      return null;
    }

    return _batteryStateGaugeCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createObservableGauge(
          batteryStateMetricName,
          description: 'Current battery state (charging/discharging/full).',
          callback: (result) {
            final state = _batteryState;
            if (_disposed || state == null) {
              return;
            }
            result.observe(
              1,
              attributes: <String, Object>{...staticAttributes, 'state': state},
            );
          },
        );
  }

  Counter<int>? get _thermalCounter {
    if (!Otel.isInitialized || !trackThermalMetrics) {
      return null;
    }

    return _thermalCounterCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createIntCounter(
          thermalCountMetricName,
          description: 'Count of thermal state transitions.',
        );
  }

  ObservableGauge<double>? get _rssGauge {
    if (!Otel.isInitialized || !trackRssMetrics) {
      return null;
    }

    return _rssGaugeCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.0')
        .createObservableGauge(
          processRssMetricName,
          unit: 'By',
          description: 'Process resident set size sampled at collection.',
          callback: (result) {
            if (_disposed) {
              return;
            }
            try {
              result.observe(
                ProcessInfo.currentRss.toDouble(),
                attributes: staticAttributes,
              );
            } catch (_) {
              // Telemetria nunca quebra o host: falha ao ler RSS apenas
              // resulta em nenhuma observação neste ciclo.
            }
          },
        );
  }

  /// Records the current free storage bytes for [milestone] (e.g.
  /// `before_photo_write`, `before_sync`, `startup`). No-op when storage
  /// tracking is disabled or no getter was injected. Never records a path or
  /// filename attribute — only the milestone label and the byte value.
  Future<void> recordStorageMilestone(String milestone) async {
    if (!trackStorageMetrics || storageFreeBytesGetter == null) {
      return;
    }

    int? bytes;
    try {
      bytes = await storageFreeBytesGetter!();
    } catch (_) {
      return;
    }
    if (bytes == null) {
      return;
    }

    _storageMilestoneBytes[milestone] = bytes;
    // Touch the getter so the instrument is created lazily on first use.
    // ignore: unnecessary_statements
    _storageGauge;
  }

  /// Records the current battery level (0-100) for [moment] (e.g. `startup`,
  /// `before_sync`). The numeric level is only ever the histogram value —
  /// never an attribute. No-op when battery tracking is disabled.
  Future<void> recordBatteryMoment(String moment) async {
    if (!trackBatteryMetrics) {
      return;
    }

    int level;
    try {
      level = await _batteryLevelGetter();
    } catch (_) {
      return;
    }

    _batteryLevelHistogram?.record(
      level.toDouble(),
      attributes: <String, Object>{...staticAttributes, 'moment': moment},
    );
  }

  /// Starts subscriptions for signals that require live streams (battery
  /// state, thermal state). Disabled signals are never subscribed.
  ///
  /// Idempotent-safe: cancels any subscription from a previous [start] call
  /// before re-subscribing, so calling it twice (or start→dispose→start)
  /// never leaks a subscription.
  void start() {
    _disposed = false;
    if (trackBatteryMetrics) {
      // Touch the gauge so the instrument is created even if the state
      // stream never emits before the first collection.
      // ignore: unnecessary_statements
      _batteryStateGauge;
      unawaited(_batteryStateSubscription?.cancel());
      _batteryStateSubscription = _batteryStateStreamGetter().listen(
        (state) {
          _batteryState = state;
        },
        onError: (Object error, StackTrace stackTrace) {
          // Telemetria nunca quebra o host: um erro no stream de estado da
          // bateria apenas mantém o último estado conhecido (ou nenhum).
        },
      );
    }

    if (trackRssMetrics) {
      // Touch the gauge so the instrument is created even before the first
      // export cycle reads it.
      // ignore: unnecessary_statements
      _rssGauge;
    }

    if (trackThermalMetrics && thermalStateStreamGetter != null) {
      unawaited(_thermalSubscription?.cancel());
      // Every subscription takes its own baseline: a state remembered from a
      // previous subscription must not turn the first new reading into a
      // transition.
      _lastThermalState = null;
      _thermalSubscription = thermalStateStreamGetter!().listen(
        (state) {
          final previous = _lastThermalState;
          _lastThermalState = state;
          // The first reading is the baseline, not a transition.
          if (previous == null || previous == state) {
            return;
          }
          _thermalCounter?.add(
            1,
            attributes: <String, Object>{...staticAttributes, 'state': state},
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          // Telemetria nunca quebra o host: um erro no stream térmico apenas
          // interrompe a contagem daquele ciclo, sem propagar a exceção.
        },
      );
    }
  }

  /// Cancels active subscriptions and silences this observer's gauges.
  void dispose() {
    _disposed = true;
    _thermalSubscription?.cancel();
    _thermalSubscription = null;
    _batteryStateSubscription?.cancel();
    _batteryStateSubscription = null;
  }
}
