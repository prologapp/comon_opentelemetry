import '../core/instrumentation_scope.dart';
import '../core/resource.dart';
import 'meter.dart';
import 'metric_data.dart';
import 'metric_reader.dart';

/// Internal contract for metric instruments that can produce [MetricData].
abstract interface class CollectibleMetric {
  /// Collects the current metric data snapshot.
  MetricData collect(Resource resource, {required int metricCardinalityLimit});
}

/// Owns meters, instruments, and metric readers for a resource.
final class MeterProvider {
  /// Creates a meter provider with [resource] and attached [readers].
  MeterProvider({
    required this.resource,
    required List<MetricReader> readers,
    this.metricCardinalityLimit = 2000,
  }) : _readers = List<MetricReader>.unmodifiable(readers) {
    for (final reader in _readers) {
      reader.attach(this);
    }
  }

  /// Resource attached to emitted metric data.
  final Resource resource;

  /// Maximum number of distinct attribute sets retained per metric.
  final int metricCardinalityLimit;
  final List<MetricReader> _readers;
  final List<CollectibleMetric> _metrics = <CollectibleMetric>[];

  /// Returns a meter for a specific instrumentation library or package.
  Meter getMeter(
    String name, {
    String? version,
    String? schemaUrl,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return Meter(
      provider: this,
      scope: InstrumentationScope(
        name: name,
        version: version,
        schemaUrl: schemaUrl,
        attributes: attributes,
      ),
    );
  }

  /// Registers a metric instrument with this provider.
  void registerMetric(CollectibleMetric metric) {
    _metrics.add(metric);
  }

  /// Collects data from all registered instruments.
  List<MetricData> collectAll() {
    final resolvedMetricCardinalityLimit = metricCardinalityLimit > 0
        ? metricCardinalityLimit
        : 2000;

    final collected = <MetricData>[];
    for (final metric in _metrics) {
      try {
        final data = metric.collect(
          resource,
          metricCardinalityLimit: resolvedMetricCardinalityLimit,
        );
        if (data.points.isNotEmpty) {
          collected.add(data);
        }
      } catch (_) {
        // A failing instrument (e.g. an observable callback that throws)
        // only loses its own data point for this cycle; it must not stop
        // the other instruments from being collected.
      }
    }
    return collected.toList(growable: false);
  }

  /// Flushes all attached metric readers.
  Future<void> forceFlush() async {
    for (final reader in _readers) {
      try {
        await reader.forceFlush();
      } catch (_) {
        // One failing reader must not keep the others from flushing.
        // Telemetry never throws into the host.
      }
    }
  }

  /// Shuts down all attached metric readers.
  Future<void> shutdown() async {
    for (final reader in _readers) {
      await reader.shutdown();
    }
  }
}
