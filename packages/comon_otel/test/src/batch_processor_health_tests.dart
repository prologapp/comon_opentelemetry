part of '../comon_otel_test.dart';

final class _GatedSpanExporter implements SpanExporter {
  final List<int> batchSizes = <int>[];
  final Completer<void> gate = Completer<void>();

  /// Ordem de export e teardown: `export-start`, `export-done`, `shutdown`.
  final List<String> events = <String>[];

  @override
  Future<ExportResult> export(List<SpanData> spans) async {
    batchSizes.add(spans.length);
    events.add('export-start');
    await gate.future;
    events.add('export-done');
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    events.add('shutdown');
  }
}

final class _GatedLogExporter implements LogExporter {
  final List<int> batchSizes = <int>[];
  final Completer<void> gate = Completer<void>();

  /// Ordem de export e teardown: `export-start`, `export-done`, `shutdown`.
  final List<String> events = <String>[];

  @override
  Future<ExportResult> export(List<LogRecord> logs) async {
    batchSizes.add(logs.length);
    events.add('export-start');
    await gate.future;
    events.add('export-done');
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    events.add('shutdown');
  }
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
    test(
      'span timer ticks do not queue flushes behind a slow export',
      () async {
        final gated = _GatedSpanExporter();
        final processor = BatchSpanProcessor(
          exporter: gated,
          maxBatchSize: 1000,
          maxQueueSize: 1000,
          scheduleDelay: const Duration(milliseconds: 10),
        );
        final tracer = TracerProvider(
          resource: Resource.empty(),
          spanProcessors: <SpanProcessor>[processor],
          sampler: const AlwaysOnSampler(),
        ).getTracer('t');

        await tracer.startSpan('first').end();
        // ~20 ticks while the first timer export is stuck.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tracer.startSpan('second').end();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(gated.batchSizes, <int>[1]);
        expect(processor.queuedFlushCount, lessThanOrEqualTo(1));

        gated.gate.complete();
        await processor.shutdown();
        expect(gated.batchSizes.fold<int>(0, (a, b) => a + b), 2);
      },
    );

    test('log timer ticks do not queue flushes behind a slow export', () async {
      final gated = _GatedLogExporter();
      final processor = BatchLogProcessor(
        exporter: gated,
        maxBatchSize: 1000,
        maxQueueSize: 1000,
        scheduleDelay: const Duration(milliseconds: 10),
      );
      final logger = LoggerProvider(
        resource: Resource.empty(),
        logProcessors: <LogProcessor>[processor],
      ).getLogger('l');

      logger.info('first');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      logger.info('second');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gated.batchSizes, <int>[1]);
      expect(processor.queuedFlushCount, lessThanOrEqualTo(1));

      gated.gate.complete();
      await processor.shutdown();
      expect(gated.batchSizes.fold<int>(0, (a, b) => a + b), 2);
    });
  });

  // forceFlush e shutdown esperam no máximo flushWaitLimit: um coletor que
  // aceita e nunca responde segurava o chamador por 30 s (shutdown) e até
  // 122 s (forceFlush com 1.536 spans = 12 exports seriais). O export em voo
  // não é cancelado: só deixa de ser aguardado.
  group('batch processor bounded flush', () {
    const limit = Duration(milliseconds: 200);
    const outer = Duration(seconds: 3);

    void expectNearLimit(Duration elapsed) {
      expect(elapsed, greaterThan(const Duration(milliseconds: 150)));
      expect(elapsed, lessThan(const Duration(milliseconds: 1500)));
    }

    Tracer spanTracer(BatchSpanProcessor processor) => TracerProvider(
      resource: Resource.empty(),
      spanProcessors: <SpanProcessor>[processor],
      sampler: const AlwaysOnSampler(),
    ).getTracer('t');

    OtelLogger logLogger(BatchLogProcessor processor) => LoggerProvider(
      resource: Resource.empty(),
      logProcessors: <LogProcessor>[processor],
    ).getLogger('l');

    test(
      'span forceFlush returns near the limit with a stuck exporter',
      () async {
        final gated = _GatedSpanExporter();
        final processor = BatchSpanProcessor(
          exporter: gated,
          scheduleDelay: const Duration(hours: 1),
          flushWaitLimit: limit,
        );
        await spanTracer(processor).startSpan('stuck').end();

        final stopwatch = Stopwatch()..start();
        await processor.forceFlush().timeout(outer);
        stopwatch.stop();

        expectNearLimit(stopwatch.elapsed);
        gated.gate.complete();
        await processor.shutdown();
      },
    );

    test(
      'span shutdown returns near the limit with a stuck exporter',
      () async {
        final gated = _GatedSpanExporter();
        final processor = BatchSpanProcessor(
          exporter: gated,
          scheduleDelay: const Duration(hours: 1),
          flushWaitLimit: limit,
        );
        await spanTracer(processor).startSpan('stuck').end();

        final stopwatch = Stopwatch()..start();
        await processor.shutdown().timeout(outer);
        stopwatch.stop();

        expectNearLimit(stopwatch.elapsed);
        gated.gate.complete();
      },
    );

    test(
      'log forceFlush returns near the limit with a stuck exporter',
      () async {
        final gated = _GatedLogExporter();
        final processor = BatchLogProcessor(
          exporter: gated,
          scheduleDelay: const Duration(hours: 1),
          flushWaitLimit: limit,
        );
        logLogger(processor).info('stuck');

        final stopwatch = Stopwatch()..start();
        await processor.forceFlush().timeout(outer);
        stopwatch.stop();

        expectNearLimit(stopwatch.elapsed);
        gated.gate.complete();
        await processor.shutdown();
      },
    );

    test('log shutdown returns near the limit with a stuck exporter', () async {
      final gated = _GatedLogExporter();
      final processor = BatchLogProcessor(
        exporter: gated,
        scheduleDelay: const Duration(hours: 1),
        flushWaitLimit: limit,
      );
      logLogger(processor).info('stuck');

      final stopwatch = Stopwatch()..start();
      await processor.shutdown().timeout(outer);
      stopwatch.stop();

      expectNearLimit(stopwatch.elapsed);
      gated.gate.complete();
    });

    test('a forceFlush that stopped waiting still exports the rest', () async {
      final gated = _GatedSpanExporter();
      final processor = BatchSpanProcessor(
        exporter: gated,
        maxBatchSize: 4,
        scheduleDelay: const Duration(hours: 1),
        flushWaitLimit: limit,
      );
      final tracer = spanTracer(processor);
      for (var i = 0; i < 10; i++) {
        await tracer.startSpan('rest-$i').end();
      }

      await processor.forceFlush().timeout(outer);
      expect(gated.batchSizes, <int>[4]);

      gated.gate.complete();
      await _waitFor(() => processor.queueLength == 0);
      await _waitFor(() => gated.events.last == 'export-done');

      expect(gated.batchSizes, <int>[4, 4, 2]);
      await processor.shutdown();
    });

    test('a shutdown that stopped waiting shuts the exporter down only after '
        'the in-flight export ends', () async {
      final gated = _GatedLogExporter();
      final processor = BatchLogProcessor(
        exporter: gated,
        scheduleDelay: const Duration(hours: 1),
        flushWaitLimit: limit,
      );
      logLogger(processor).info('in-flight');

      await processor.shutdown().timeout(outer);
      expect(gated.events, <String>['export-start']);

      gated.gate.complete();
      await _waitFor(() => gated.events.contains('shutdown'));

      expect(gated.events, <String>['export-start', 'export-done', 'shutdown']);
    });
  });
}
