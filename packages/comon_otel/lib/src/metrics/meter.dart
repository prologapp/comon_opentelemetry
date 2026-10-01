import '../core/instrumentation_scope.dart';
import '../core/resource.dart';
import 'instruments/counter.dart';
import 'instruments/histogram.dart';
import 'instruments/observable_counter.dart';
import 'instruments/observable_gauge.dart';
import 'instruments/up_down_counter.dart';
import 'meter_provider.dart';
import 'metric_data.dart';

const Map<String, Object> _metricOverflowAttributes = <String, Object>{
  'otel.metric.overflow': true,
};

final class _AttributeSetKey {
  const _AttributeSetKey(this.attributes);

  final Map<String, Object> attributes;

  @override
  bool operator ==(Object other) {
    if (other is! _AttributeSetKey) {
      return false;
    }
    if (attributes.length != other.attributes.length) {
      return false;
    }
    for (final entry in attributes.entries) {
      if (other.attributes[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    var hash = 0;
    for (final entry in attributes.entries) {
      hash ^= Object.hash(entry.key, entry.value);
    }
    return hash;
  }
}

Map<String, Object> _normalizeMetricAttributes(
  Map<String, Object>? attributes,
) {
  if (attributes == null || attributes.isEmpty) {
    return const <String, Object>{};
  }

  return Map<String, Object>.unmodifiable(Map<String, Object>.from(attributes));
}

Map<String, Object> _resolveRetainedAttributes({
  required Map<String, Object> attributes,
  required Map<_AttributeSetKey, Map<String, Object>> retainedAttributeSets,
  required int metricCardinalityLimit,
}) {
  final key = _AttributeSetKey(attributes);
  final retained = retainedAttributeSets[key];
  if (retained != null) {
    return retained;
  }

  if (retainedAttributeSets.length < metricCardinalityLimit) {
    retainedAttributeSets[key] = attributes;
    return attributes;
  }

  return _metricOverflowAttributes;
}

/// Creates metric instruments for a specific instrumentation scope.
final class Meter {
  /// Creates a meter bound to [scope] and backed by [provider].
  Meter({required MeterProvider provider, required this.scope})
    : _provider = provider;

  final MeterProvider _provider;

  /// Instrumentation scope reported on emitted metric data.
  final InstrumentationScope scope;

  int get _metricCardinalityLimit =>
      _resolveMetricCardinalityLimit(_provider.metricCardinalityLimit);

  /// Name of the current instrumentation scope.
  String get name => scope.name;

  /// Optional version of the current instrumentation scope.
  String? get version => scope.version;

  /// Optional schema URL associated with the instrumentation scope.
  String? get schemaUrl => scope.schemaUrl;

  /// Additional instrumentation scope attributes attached to metric data.
  Map<String, Object> get attributes => scope.attributes;

  /// Creates a monotonic integer counter.
  Counter<int> createIntCounter(
    String name, {
    String? unit,
    String? description,
  }) {
    final instrument = _CounterMetric<int>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      instrumentType: MetricInstrumentType.counter,
      allowNegative: false,
      metricCardinalityLimit: _metricCardinalityLimit,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }

  /// Creates a monotonic double counter.
  Counter<double> createDoubleCounter(
    String name, {
    String? unit,
    String? description,
  }) {
    final instrument = _CounterMetric<double>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      instrumentType: MetricInstrumentType.counter,
      allowNegative: false,
      metricCardinalityLimit: _metricCardinalityLimit,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }

  /// Creates an integer up-down counter.
  UpDownCounter<int> createIntUpDownCounter(
    String name, {
    String? unit,
    String? description,
  }) {
    final instrument = _CounterMetric<int>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      instrumentType: MetricInstrumentType.upDownCounter,
      allowNegative: true,
      metricCardinalityLimit: _metricCardinalityLimit,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }

  /// Creates a double histogram.
  Histogram<double> createHistogram(
    String name, {
    String? unit,
    String? description,
    List<double>? boundaries,
  }) {
    final instrument = _HistogramMetric<double>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      boundaries: boundaries,
      metricCardinalityLimit: _metricCardinalityLimit,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }

  /// Creates an observable double gauge.
  ObservableGauge<double> createObservableGauge(
    String name, {
    required ObservableCallback<double> callback,
    String? unit,
    String? description,
  }) {
    final instrument = _ObservableMetric<double>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      instrumentType: MetricInstrumentType.observableGauge,
      callback: callback,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }

  /// Creates an observable integer counter.
  ObservableCounter<int> createObservableCounter(
    String name, {
    required ObservableCallback<int> callback,
    String? unit,
    String? description,
  }) {
    final instrument = _ObservableMetric<int>(
      scope: scope,
      name: name,
      unit: unit,
      description: description,
      instrumentType: MetricInstrumentType.observableCounter,
      callback: callback,
    );
    _provider.registerMetric(instrument);
    return instrument;
  }
}

/// Collector passed into observable instrument callbacks.
final class ObservableResult<T extends num> {
  /// Creates an observable collection result.
  ObservableResult({required this.metricCardinalityLimit});

  /// Maximum number of distinct attribute sets retained for this collection.
  final int metricCardinalityLimit;
  final Map<_AttributeSetKey, Map<String, Object>> _retainedAttributeSets =
      <_AttributeSetKey, Map<String, Object>>{};
  final List<MetricPoint> _points = <MetricPoint>[];

  /// Records an observation for the current collection cycle.
  void observe(T value, {Map<String, Object>? attributes}) {
    final normalizedAttributes = _normalizeMetricAttributes(attributes);
    _points.add(
      MetricPoint(
        value: value,
        timestamp: DateTime.now().toUtc(),
        attributes: _resolveRetainedAttributes(
          attributes: normalizedAttributes,
          retainedAttributeSets: _retainedAttributeSets,
          metricCardinalityLimit: metricCardinalityLimit,
        ),
      ),
    );
  }
}

/// Resolves the provider's cardinality limit the same way
/// [MeterProvider.collectAll] does (non-positive falls back to 2000).
int _resolveMetricCardinalityLimit(int limit) => limit > 0 ? limit : 2000;

/// Running cumulative sum of one attribute set of a counter.
final class _SumSeries {
  _SumSeries({
    required this.attributes,
    required this.sum,
    required this.startTimestamp,
  }) : timestamp = startTimestamp;

  final Map<String, Object> attributes;
  num sum;
  final DateTime startTimestamp;
  DateTime timestamp;
}

/// Running cumulative distribution of one attribute set of a histogram.
final class _HistogramSeries {
  _HistogramSeries({
    required this.attributes,
    required int bucketCount,
    required this.startTimestamp,
  }) : timestamp = startTimestamp,
       bucketCounts = List<int>.filled(bucketCount, 0);

  final Map<String, Object> attributes;
  final List<int> bucketCounts;
  final DateTime startTimestamp;
  DateTime timestamp;
  int count = 0;
  double sum = 0;
  double min = 0;
  double max = 0;
}

final class _CounterMetric<T extends num>
    implements Counter<T>, UpDownCounter<T>, CollectibleMetric {
  _CounterMetric({
    required this.scope,
    required this.name,
    required this.instrumentType,
    required this.allowNegative,
    required this.metricCardinalityLimit,
    this.unit,
    this.description,
  });

  final InstrumentationScope scope;
  final String name;
  final String? unit;
  final String? description;
  final MetricInstrumentType instrumentType;
  final bool allowNegative;

  /// Maximum number of distinct attribute sets kept by this instrument.
  final int metricCardinalityLimit;

  // Aggregated at record time: memory and collect cost are O(series), not
  // O(measurements). Insertion order = first-seen order of each series.
  final Map<_AttributeSetKey, _SumSeries> _series =
      <_AttributeSetKey, _SumSeries>{};
  final Map<_AttributeSetKey, Map<String, Object>> _retainedAttributeSets =
      <_AttributeSetKey, Map<String, Object>>{};

  @override
  void add(T value, {Map<String, Object>? attributes}) {
    // NaN/Infinity would poison the cumulative sum for the rest of the
    // process (and cannot be represented as a JSON number): drop it.
    if (!value.isFinite) {
      return;
    }
    if (!allowNegative && value < 0) {
      throw ArgumentError.value(value, 'value', 'Counter values must be >= 0.');
    }
    final now = DateTime.now().toUtc();
    final resolvedAttributes = _resolveRetainedAttributes(
      attributes: _normalizeMetricAttributes(attributes),
      retainedAttributeSets: _retainedAttributeSets,
      metricCardinalityLimit: metricCardinalityLimit,
    );
    final key = _AttributeSetKey(resolvedAttributes);
    final series = _series[key];
    if (series == null) {
      _series[key] = _SumSeries(
        attributes: resolvedAttributes,
        sum: value,
        startTimestamp: now,
      );
      return;
    }
    series
      ..sum = series.sum + value
      ..timestamp = now;
  }

  @override
  MetricData collect(Resource resource, {required int metricCardinalityLimit}) {
    return MetricData(
      name: name,
      description: description,
      unit: unit,
      instrumentType: instrumentType,
      resource: resource,
      scope: scope,
      aggregationTemporality: AggregationTemporality.cumulative,
      isMonotonic: !allowNegative,
      points: _series.values
          .map(
            (series) => MetricPoint(
              value: series.sum,
              timestamp: series.timestamp,
              startTimestamp: series.startTimestamp,
              attributes: series.attributes,
            ),
          )
          .toList(growable: false),
    );
  }
}

final class _HistogramMetric<T extends num>
    implements Histogram<T>, CollectibleMetric {
  _HistogramMetric({
    required this.scope,
    required this.name,
    required this.metricCardinalityLimit,
    this.unit,
    this.description,
    List<double>? boundaries,
  }) : explicitBounds = List<double>.unmodifiable(
         boundaries ?? const <double>[],
       );

  final InstrumentationScope scope;
  final String name;
  final String? unit;
  final String? description;

  /// Bucket bounds, copied at creation: the caller may keep mutating the
  /// list it passed, but the bucket layout of a cumulative series must
  /// never change after its first measurement.
  final List<double> explicitBounds;

  /// Maximum number of distinct attribute sets kept by this instrument.
  final int metricCardinalityLimit;

  // Aggregated at record time: memory and collect cost are O(series), not
  // O(measurements). Insertion order = first-seen order of each series.
  final Map<_AttributeSetKey, _HistogramSeries> _series =
      <_AttributeSetKey, _HistogramSeries>{};
  final Map<_AttributeSetKey, Map<String, Object>> _retainedAttributeSets =
      <_AttributeSetKey, Map<String, Object>>{};

  @override
  void record(T value, {Map<String, Object>? attributes}) {
    // NaN/Infinity would poison sum/min/max for the rest of the process (and
    // cannot be represented as a JSON number): drop the measurement.
    if (!value.isFinite) {
      return;
    }
    final now = DateTime.now().toUtc();
    final resolvedAttributes = _resolveRetainedAttributes(
      attributes: _normalizeMetricAttributes(attributes),
      retainedAttributeSets: _retainedAttributeSets,
      metricCardinalityLimit: metricCardinalityLimit,
    );
    final series = _series.putIfAbsent(
      _AttributeSetKey(resolvedAttributes),
      () => _HistogramSeries(
        attributes: resolvedAttributes,
        bucketCount: explicitBounds.length + 1,
        startTimestamp: now,
      ),
    );

    final doubleValue = value.toDouble();
    if (series.count == 0) {
      series
        ..min = doubleValue
        ..max = doubleValue;
    } else {
      series
        ..min = series.min < doubleValue ? series.min : doubleValue
        ..max = series.max > doubleValue ? series.max : doubleValue;
    }
    series
      ..count += 1
      ..sum += doubleValue
      ..timestamp = now;

    var index = explicitBounds.length;
    for (var boundIndex = 0; boundIndex < explicitBounds.length; boundIndex++) {
      if (doubleValue <= explicitBounds[boundIndex]) {
        index = boundIndex;
        break;
      }
    }
    series.bucketCounts[index] += 1;
  }

  @override
  MetricData collect(Resource resource, {required int metricCardinalityLimit}) {
    return MetricData(
      name: name,
      description: description,
      unit: unit,
      instrumentType: MetricInstrumentType.histogram,
      resource: resource,
      scope: scope,
      aggregationTemporality: AggregationTemporality.cumulative,
      points: _series.values
          .map(
            (series) => MetricPoint(
              value: series.sum,
              timestamp: series.timestamp,
              startTimestamp: series.startTimestamp,
              attributes: series.attributes,
              count: series.count,
              sum: series.sum,
              min: series.min,
              max: series.max,
              // Snapshot: exporters may hold the point (in-memory) or
              // re-encode it on retry, so it must not change afterwards.
              bucketCounts: List<int>.unmodifiable(series.bucketCounts),
              explicitBounds: explicitBounds,
            ),
          )
          .toList(growable: false),
    );
  }
}

final class _ObservableMetric<T extends num>
    implements ObservableGauge<T>, ObservableCounter<T>, CollectibleMetric {
  _ObservableMetric({
    required this.scope,
    required this.name,
    required this.instrumentType,
    required this.callback,
    this.unit,
    this.description,
  });

  final InstrumentationScope scope;
  final String name;
  final String? unit;
  final String? description;
  final MetricInstrumentType instrumentType;
  final ObservableCallback<T> callback;

  @override
  MetricData collect(Resource resource, {required int metricCardinalityLimit}) {
    final result = ObservableResult<T>(
      metricCardinalityLimit: metricCardinalityLimit,
    );
    callback(result);
    return MetricData(
      name: name,
      description: description,
      unit: unit,
      instrumentType: instrumentType,
      resource: resource,
      scope: scope,
      aggregationTemporality: switch (instrumentType) {
        MetricInstrumentType.observableCounter =>
          AggregationTemporality.cumulative,
        _ => AggregationTemporality.unspecified,
      },
      isMonotonic: switch (instrumentType) {
        MetricInstrumentType.observableCounter => true,
        _ => null,
      },
      points: List<MetricPoint>.unmodifiable(result._points),
    );
  }
}
