part of '../comon_otel_test.dart';

final class _GatedSpanExporter implements SpanExporter {
  final List<int> batchSizes = <int>[];
  final Completer<void> gate = Completer<void>();

  @override
  Future<ExportResult> export(List<SpanData> spans) async {
    batchSizes.add(spans.length);
    await gate.future;
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

final class _GatedLogExporter implements LogExporter {
  final List<int> batchSizes = <int>[];
  final Completer<void> gate = Completer<void>();

  @override
  Future<ExportResult> export(List<LogRecord> logs) async {
    batchSizes.add(logs.length);
    await gate.future;
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

void defineBatchProcessorHealthTests() {
  group('batch processor health hooks', () {
    test('queueLength reports queued spans below the cap', () async {
      final batchExporter = InMemorySpanExporter();
      final processor = BatchSpanProcessor(
        exporter: batchExporter,
        maxBatchSize: 1000,
        maxQueueSize: 10,
        scheduleDelay: const Duration(hours: 1),
      );

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'batch-health-span-depth',
        spanProcessors: <SpanProcessor>[processor],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
      );

      for (var i = 0; i < 3; i++) {
        await Otel.instance.tracer.traceAsync('depth-$i', fn: () async {});
      }

      expect(processor.queueLength, 3);
    });

    test('invokes onDrop and caps the queue when spans overflow', () async {
      var drops = 0;
      final batchExporter = InMemorySpanExporter();
      final processor = BatchSpanProcessor(
        exporter: batchExporter,
        maxBatchSize: 1000,
        maxQueueSize: 2,
        scheduleDelay: const Duration(hours: 1),
        onDrop: () => drops++,
      );

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'batch-health-span-overflow',
        spanProcessors: <SpanProcessor>[processor],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
      );

      for (var i = 0; i < 5; i++) {
        await Otel.instance.tracer.traceAsync('overflow-$i', fn: () async {});
      }

      expect(drops, 3);
      expect(processor.queueLength, 2);
    });

    test('queueLength reports queued logs below the cap', () async {
      final batchExporter = InMemoryLogExporter();
      final processor = BatchLogProcessor(
        exporter: batchExporter,
        maxBatchSize: 1000,
        maxQueueSize: 10,
        scheduleDelay: const Duration(hours: 1),
      );

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'batch-health-log-depth',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[processor],
      );

      for (var i = 0; i < 3; i++) {
        Otel.instance.logger.info('depth-$i');
      }

      expect(processor.queueLength, 3);
    });

    test('invokes onDrop and caps the queue when logs overflow', () async {
      var drops = 0;
      final batchExporter = InMemoryLogExporter();
      final processor = BatchLogProcessor(
        exporter: batchExporter,
        maxBatchSize: 1000,
        maxQueueSize: 2,
        scheduleDelay: const Duration(hours: 1),
        onDrop: () => drops++,
      );

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'batch-health-log-overflow',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[processor],
      );

      for (var i = 0; i < 5; i++) {
        Otel.instance.logger.info('overflow-$i');
      }

      expect(drops, 3);
      expect(processor.queueLength, 2);
    });
    test('a throwing onDrop never breaks span end nor the queue cap', () async {
      var drops = 0;
      final processor = BatchSpanProcessor(
        exporter: InMemorySpanExporter(),
        maxBatchSize: 1000,
        maxQueueSize: 2,
        scheduleDelay: const Duration(hours: 1),
        onDrop: () {
          drops++;
          throw StateError('host drop hook failed');
        },
      );
      final tracer = TracerProvider(
        resource: Resource.empty(),
        spanProcessors: <SpanProcessor>[processor],
        sampler: const AlwaysOnSampler(),
      ).getTracer('t');

      for (var i = 0; i < 5; i++) {
        await tracer.startSpan('drop-$i').end();
      }

      expect(drops, 3);
      expect(processor.queueLength, 2);
      await processor.shutdown();
    });

    test('a throwing onDrop never breaks log emit nor the queue cap', () async {
      var drops = 0;
      final processor = BatchLogProcessor(
        exporter: InMemoryLogExporter(),
        maxBatchSize: 1000,
        maxQueueSize: 2,
        scheduleDelay: const Duration(hours: 1),
        onDrop: () {
          drops++;
          throw StateError('host drop hook failed');
        },
      );
      final logger = LoggerProvider(
        resource: Resource.empty(),
        logProcessors: <LogProcessor>[processor],
      ).getLogger('l');

      for (var i = 0; i < 5; i++) {
        logger.info('drop-$i');
      }

      expect(drops, 3);
      expect(processor.queueLength, 2);
      await processor.shutdown();
    });
    test('span flush chain stays bounded while an export is slow', () async {
      final gated = _GatedSpanExporter();
      final processor = BatchSpanProcessor(
        exporter: gated,
        maxBatchSize: 4,
        maxQueueSize: 1000,
        scheduleDelay: const Duration(hours: 1),
      );
      final tracer = TracerProvider(
        resource: Resource.empty(),
        spanProcessors: <SpanProcessor>[processor],
        sampler: const AlwaysOnSampler(),
      ).getTracer('t');

      for (var i = 0; i < 50; i++) {
        await tracer.startSpan('slow-$i').end();
      }
      expect(processor.queuedFlushCount, lessThanOrEqualTo(1));

      final flush = processor.forceFlush();
      gated.gate.complete();
      await flush;

      // Nothing lost, and no export larger than maxBatchSize.
      expect(gated.batchSizes.fold<int>(0, (a, b) => a + b), 50);
      expect(gated.batchSizes.every((size) => size <= 4), isTrue);
      expect(processor.queueLength, 0);
      await processor.shutdown();
    });

    test('log flush chain stays bounded while an export is slow', () async {
      final gated = _GatedLogExporter();
      final processor = BatchLogProcessor(
        exporter: gated,
        maxBatchSize: 4,
        maxQueueSize: 1000,
        scheduleDelay: const Duration(hours: 1),
      );
      final logger = LoggerProvider(
        resource: Resource.empty(),
        logProcessors: <LogProcessor>[processor],
      ).getLogger('l');

      for (var i = 0; i < 50; i++) {
        logger.info('slow-$i');
        await Future<void>.delayed(Duration.zero);
      }
      expect(processor.queuedFlushCount, lessThanOrEqualTo(1));

      final flush = processor.forceFlush();
      gated.gate.complete();
      await flush;

      expect(gated.batchSizes.fold<int>(0, (a, b) => a + b), 50);
      expect(gated.batchSizes.every((size) => size <= 4), isTrue);
      expect(processor.queueLength, 0);
      await processor.shutdown();
    });
  });
}
