import 'dart:ui';

import 'package:comon_otel/comon_otel.dart';

/// Observer that records Flutter frame timing metrics.
final class OtelFlutterFrameTimingObserver {
  /// Creates a frame timing observer.
  OtelFlutterFrameTimingObserver({
    this.loggerName = 'comon_otel.flutter',
    this.frameDurationMetricName = 'flutter.frame.duration',
    this.buildDurationMetricName = 'flutter.build.duration',
    this.rasterDurationMetricName = 'flutter.raster.duration',
    this.slowFrameCountMetricName = 'flutter.frame.slow.count',
    this.jankFrameCountMetricName = 'flutter.frame.jank.count',
    this.slowFrameThreshold = const Duration(milliseconds: 16),
    this.jankFrameThreshold = const Duration(milliseconds: 32),
    this.staticAttributes = const <String, Object>{},
  });

  /// Logger and meter scope name.
  final String loggerName;

  /// Metric name for total frame duration.
  final String frameDurationMetricName;

  /// Metric name for build duration.
  final String buildDurationMetricName;

  /// Metric name for raster duration.
  final String rasterDurationMetricName;

  /// Metric name for slow frame count.
  final String slowFrameCountMetricName;

  /// Metric name for jank frame count.
  final String jankFrameCountMetricName;

  /// Threshold for slow frames.
  final Duration slowFrameThreshold;

  /// Threshold for janky frames.
  final Duration jankFrameThreshold;

  /// Static attributes merged into every recorded metric (e.g.
  /// `device.tier`). Per-record attributes win on key collision.
  final Map<String, Object> staticAttributes;

  Histogram<double>? _frameDurationHistogramCache;
  Histogram<double>? _buildDurationHistogramCache;
  Histogram<double>? _rasterDurationHistogramCache;
  Counter<int>? _slowFrameCounterCache;
  Counter<int>? _jankFrameCounterCache;

  Histogram<double>? get _frameDurationHistogram {
    if (!Otel.isInitialized) {
      return null;
    }

    return _frameDurationHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.1')
        .createHistogram(
          frameDurationMetricName,
          unit: 'ms',
          description: 'Total time spent rendering a Flutter frame.',
          boundaries: <double>[8, 16, 32, 50, 100],
        );
  }

  Histogram<double>? get _buildDurationHistogram {
    if (!Otel.isInitialized) {
      return null;
    }

    return _buildDurationHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.1')
        .createHistogram(
          buildDurationMetricName,
          unit: 'ms',
          description: 'Time spent in the Flutter build phase per frame.',
          boundaries: <double>[4, 8, 16, 32, 50],
        );
  }

  Histogram<double>? get _rasterDurationHistogram {
    if (!Otel.isInitialized) {
      return null;
    }

    return _rasterDurationHistogramCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.1')
        .createHistogram(
          rasterDurationMetricName,
          unit: 'ms',
          description: 'Time spent in the Flutter raster phase per frame.',
          boundaries: <double>[4, 8, 16, 32, 50],
        );
  }

  Counter<int>? get _slowFrameCounter {
    if (!Otel.isInitialized) {
      return null;
    }

    return _slowFrameCounterCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.1')
        .createIntCounter(
          slowFrameCountMetricName,
          description:
              'Count of frames slower than the configured slow threshold.',
        );
  }

  Counter<int>? get _jankFrameCounter {
    if (!Otel.isInitialized) {
      return null;
    }

    return _jankFrameCounterCache ??= Otel.instance.meterProvider
        .getMeter(loggerName, version: '0.1.1')
        .createIntCounter(
          jankFrameCountMetricName,
          description:
              'Count of frames slower than the configured jank threshold.',
        );
  }

  /// Records a batch of frame timings from the Flutter engine.
  void onFrameTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      recordFrameSample(
        totalSpan: timing.totalSpan,
        buildDuration: timing.buildDuration,
        rasterDuration: timing.rasterDuration,
      );
    }
  }

  /// Records one synthesized frame sample.
  void recordFrameSample({
    required Duration totalSpan,
    required Duration buildDuration,
    required Duration rasterDuration,
  }) {
    if (!Otel.isInitialized) {
      return;
    }

    final totalMilliseconds = totalSpan.inMicroseconds / 1000;
    final buildMilliseconds = buildDuration.inMicroseconds / 1000;
    final rasterMilliseconds = rasterDuration.inMicroseconds / 1000;
    final attributes = <String, Object>{
      ...staticAttributes,
      'flutter.frame.slow_threshold_ms':
          slowFrameThreshold.inMicroseconds / 1000,
      'flutter.frame.jank_threshold_ms':
          jankFrameThreshold.inMicroseconds / 1000,
    };

    _frameDurationHistogram?.record(totalMilliseconds, attributes: attributes);
    _buildDurationHistogram?.record(buildMilliseconds, attributes: attributes);
    _rasterDurationHistogram?.record(
      rasterMilliseconds,
      attributes: attributes,
    );

    if (totalSpan >= jankFrameThreshold) {
      _jankFrameCounter?.add(
        1,
        attributes: <String, Object>{
          ...attributes,
          'flutter.frame.classification': 'jank',
        },
      );
      return;
    }

    if (totalSpan >= slowFrameThreshold) {
      _slowFrameCounter?.add(
        1,
        attributes: <String, Object>{
          ...attributes,
          'flutter.frame.classification': 'slow',
        },
      );
    }
  }
}
