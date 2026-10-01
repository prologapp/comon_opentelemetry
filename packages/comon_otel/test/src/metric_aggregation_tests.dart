part of '../comon_otel_test.dart';

/// Builds an isolated meter provider backed by an in-memory exporter, so the
/// tests below observe exactly what an exporter would receive per collect.
({
  MeterProvider provider,
  ExportingMetricReader reader,
  InMemoryMetricExporter sink,
})
_isolatedMeterProvider({int metricCardinalityLimit = 2000}) {
  final sink = InMemoryMetricExporter();
  final reader = ExportingMetricReader(exporter: sink);
  final provider = MeterProvider(
    resource: Resource.empty(),
    readers: <MetricReader>[reader],
    metricCardinalityLimit: metricCardinalityLimit,
  );
  return (provider: provider, reader: reader, sink: sink);
}

MetricPoint _pointWith(MetricData metric, String key, Object value) {
  return metric.points.singleWhere((point) => point.attributes[key] == value);
}

MetricPoint _overflowPoint(MetricData metric) {
  return metric.points.singleWhere(
    (point) => point.attributes['otel.metric.overflow'] == true,
  );
}

void defineMetricAggregationTests() {
  group('metric aggregation', () {
    // Expected values below are computed by hand from the recorded sequence;
    // they do not reuse any aggregation code from the SDK.

    test('int counter exports cumulative int sums per attribute set', () async {
      final h = _isolatedMeterProvider();
      final counter = h.provider.getMeter('m').createIntCounter('c.int');

      counter.add(2, attributes: <String, Object>{'k': 'a'});
      counter.add(3, attributes: <String, Object>{'k': 'a'});
      counter.add(4, attributes: <String, Object>{'k': 'b'});
      await h.reader.collect();

      final first = h.sink.lastMetricNamed('c.int')!;
      expect(first.aggregationTemporality, AggregationTemporality.cumulative);
      expect(first.isMonotonic, isTrue);
      expect(first.points, hasLength(2));
      final firstA = _pointWith(first, 'k', 'a');
      expect(firstA.value, 5);
      expect(firstA.value, isA<int>());
      expect(_pointWith(first, 'k', 'b').value, 4);

      counter.add(10, attributes: <String, Object>{'k': 'a'});
      await h.reader.collect();

      final second = h.sink.lastMetricNamed('c.int')!;
      final secondA = _pointWith(second, 'k', 'a');
      expect(secondA.value, 15);
      expect(secondA.value, isA<int>());
      expect(_pointWith(second, 'k', 'b').value, 4);
      // Cumulative: start is pinned to the first measurement of the series.
      expect(secondA.startTimestamp, firstA.startTimestamp);
      expect(secondA.timestamp.isBefore(firstA.timestamp), isFalse);
    });

    test('double counter and up-down counter keep their value types', () async {
      final h = _isolatedMeterProvider();
      final meter = h.provider.getMeter('m');
      final doubles = meter.createDoubleCounter('c.double');
      final upDown = meter.createIntUpDownCounter('c.updown');

      doubles.add(0.1);
      doubles.add(0.2);
      upDown.add(5);
      upDown.add(-7);
      await h.reader.collect();

      final doubleValue = h.sink.lastMetricNamed('c.double')!.points.single;
      expect(doubleValue.value, 0.1 + 0.2);
      expect(doubleValue.value, isA<double>());

      final upDownMetric = h.sink.lastMetricNamed('c.updown')!;
      expect(upDownMetric.isMonotonic, isFalse);
      expect(upDownMetric.points.single.value, -2);
    });

    test('point start is the first measurement and time the last', () async {
      final h = _isolatedMeterProvider();
      final meter = h.provider.getMeter('m');
      final counter = meter.createIntCounter('c.time');
      final histogram = meter.createHistogram('h.time');

      final beforeFirst = DateTime.now().toUtc();
      counter.add(1);
      histogram.record(1);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final beforeLast = DateTime.now().toUtc();
      counter.add(1);
      histogram.record(1);
      final afterLast = DateTime.now().toUtc();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await h.reader.collect();

      for (final name in <String>['c.time', 'h.time']) {
        final point = h.sink.lastMetricNamed(name)!.points.single;
        expect(point.startTimestamp!.isBefore(beforeFirst), isFalse);
        expect(point.startTimestamp!.isBefore(beforeLast), isTrue);
        expect(point.timestamp.isBefore(beforeLast), isFalse);
        expect(point.timestamp.isAfter(afterLast), isFalse);
      }
    });

    test(
      'histogram exports cumulative count, sum, min, max and buckets',
      () async {
        final h = _isolatedMeterProvider();
        final histogram = h.provider
            .getMeter('m')
            .createHistogram('h.buckets', boundaries: <double>[0, 5, 10]);

        // Buckets: (-inf,0] (0,5] (5,10] (10,+inf) — a value equal to a bound
        // falls into the bucket whose upper bound it is.
        for (final value in <double>[5, 0, -1, 7, 11, 10]) {
          histogram.record(value);
        }
        await h.reader.collect();

        final first = h.sink.lastMetricNamed('h.buckets')!;
        expect(first.aggregationTemporality, AggregationTemporality.cumulative);
        final firstPoint = first.points.single;
        expect(firstPoint.count, 6);
        expect(firstPoint.sum, 32.0);
        expect(firstPoint.value, 32.0);
        expect(firstPoint.min, -1.0);
        expect(firstPoint.max, 11.0);
        expect(firstPoint.bucketCounts, <int>[2, 1, 2, 1]);
        expect(firstPoint.explicitBounds, <double>[0, 5, 10]);

        histogram.record(3);
        await h.reader.collect();

        final secondPoint = h.sink.lastMetricNamed('h.buckets')!.points.single;
        expect(secondPoint.count, 7);
        expect(secondPoint.sum, 35.0);
        expect(secondPoint.min, -1.0);
        expect(secondPoint.max, 11.0);
        expect(secondPoint.bucketCounts, <int>[2, 2, 2, 1]);
        expect(secondPoint.startTimestamp, firstPoint.startTimestamp);

        // An exported snapshot must not change after later measurements.
        expect(firstPoint.count, 6);
        expect(firstPoint.bucketCounts, <int>[2, 1, 2, 1]);
      },
    );

    test('histogram cardinality overflow aggregates into one series', () async {
      final h = _isolatedMeterProvider(metricCardinalityLimit: 2);
      final histogram = h.provider.getMeter('m').createHistogram('h.overflow');

      histogram.record(1, attributes: <String, Object>{'r': 'a'});
      histogram.record(2, attributes: <String, Object>{'r': 'b'});
      histogram.record(3, attributes: <String, Object>{'r': 'c'});
      histogram.record(4, attributes: <String, Object>{'r': 'd'});
      histogram.record(5, attributes: <String, Object>{'r': 'a'});
      await h.reader.collect();

      final metric = h.sink.lastMetricNamed('h.overflow')!;
      expect(metric.points, hasLength(3));

      final a = _pointWith(metric, 'r', 'a');
      expect(a.count, 2);
      expect(a.sum, 6.0);
      expect(a.min, 1.0);
      expect(a.max, 5.0);

      final b = _pointWith(metric, 'r', 'b');
      expect(b.count, 1);
      expect(b.sum, 2.0);

      final overflow = _overflowPoint(metric);
      expect(overflow.count, 2);
      expect(overflow.sum, 7.0);
      expect(overflow.min, 3.0);
      expect(overflow.max, 4.0);
      expect(overflow.attributes, <String, Object>{
        'otel.metric.overflow': true,
      });
    });

    test(
      'counter overflow keeps the first attribute sets across collects',
      () async {
        final h = _isolatedMeterProvider(metricCardinalityLimit: 1);
        final counter = h.provider.getMeter('m').createIntCounter('c.overflow');

        counter.add(1, attributes: <String, Object>{'r': 'a'});
        counter.add(2, attributes: <String, Object>{'r': 'b'});
        await h.reader.collect();
        counter.add(4, attributes: <String, Object>{'r': 'c'});
        counter.add(8, attributes: <String, Object>{'r': 'a'});
        await h.reader.collect();

        final metric = h.sink.lastMetricNamed('c.overflow')!;
        expect(metric.points, hasLength(2));
        expect(_pointWith(metric, 'r', 'a').value, 9);
        expect(_overflowPoint(metric).value, 6);
      },
    );

    test(
      'collect cost does not grow with the number of measurements',
      () async {
        // Same single series, two very different measurement counts. With
        // per-series aggregation the collect cost is O(series); keeping the
        // measurement history makes it O(measurements) (~100x here).
        Future<Duration> collectAfter(int measurements) async {
          final h = _isolatedMeterProvider();
          final meter = h.provider.getMeter('m');
          final histogram = meter.createHistogram(
            'h.cost',
            boundaries: <double>[1, 5, 10, 50],
          );
          final counter = meter.createIntCounter('c.cost');
          for (var i = 0; i < measurements; i++) {
            histogram.record((i % 60).toDouble());
            counter.add(1);
          }
          // Warm-up so the timed collect is not dominated by JIT.
          await h.reader.collect();
          h.sink.clear();
          // Enough cycles that one GC pause cannot dominate the ratio.
          final stopwatch = Stopwatch()..start();
          for (var i = 0; i < 200; i++) {
            await h.reader.collect();
          }
          stopwatch.stop();
          expect(
            h.sink.lastMetricNamed('h.cost')!.points.single.count,
            measurements,
          );
          return stopwatch.elapsed;
        }

        final small = await collectAfter(2000);
        final large = await collectAfter(200000);
        final ratio =
            large.inMicroseconds /
            (small.inMicroseconds == 0 ? 1 : small.inMicroseconds);
        expect(
          ratio,
          lessThan(10),
          reason: 'collect took $small for 2k and $large for 200k measurements',
        );
      },
    );
  });
}
