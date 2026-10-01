part of '../comon_otel_test.dart';

Map<String, Object?> _singleJsonBody(_FakeOtlpHttpTransport transport) {
  return jsonDecode(transport.requests.single.request.body)
      as Map<String, Object?>;
}

List<Map<String, Object?>> _jsonMetrics(Map<String, Object?> payload) {
  final resourceMetrics = payload['resourceMetrics'] as List<Object?>;
  return <Map<String, Object?>>[
    for (final resource in resourceMetrics)
      for (final scope
          in (resource as Map<String, Object?>)['scopeMetrics']
              as List<Object?>)
        for (final metric
            in (scope as Map<String, Object?>)['metrics'] as List<Object?>)
          metric as Map<String, Object?>,
  ];
}

final class _ThrowingMetricExporter implements MetricExporter {
  int exportCalls = 0;

  @override
  Future<ExportResult> export(List<MetricData> metrics) async {
    exportCalls += 1;
    throw StateError('metric export failed');
  }

  @override
  Future<void> forceFlush() async {
    throw StateError('metric flush failed');
  }

  @override
  Future<void> shutdown() async {}
}

final class _SlowMetricExporter implements MetricExporter {
  _SlowMetricExporter(this.delay);

  final Duration delay;
  int calls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<ExportResult> export(List<MetricData> metrics) async {
    calls += 1;
    inFlight += 1;
    if (inFlight > maxInFlight) {
      maxInFlight = inFlight;
    }
    try {
      await Future<void>.delayed(delay);
      return ExportResult.success;
    } finally {
      inFlight -= 1;
    }
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {}
}

final class _ShutdownProbe {
  bool throws = false;
  int shutdowns = 0;

  Future<void> shutdown() async {
    shutdowns += 1;
    if (throws) {
      throw StateError('shutdown failed');
    }
  }
}

final class _ProbeMetricReader implements MetricReader {
  _ProbeMetricReader(this.probe);

  final _ShutdownProbe probe;

  @override
  void attach(MeterProvider provider) {}

  @override
  Future<void> collect() async {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() => probe.shutdown();
}

final class _ProbeSpanProcessor implements SpanProcessor {
  _ProbeSpanProcessor(this.probe);

  final _ShutdownProbe probe;

  @override
  void onStart(Span span) {}

  @override
  void onEnd(Span span) {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() => probe.shutdown();
}

final class _ProbeLogProcessor implements LogProcessor {
  _ProbeLogProcessor(this.probe);

  final _ShutdownProbe probe;

  @override
  void onEmit(LogRecord record) {}

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() => probe.shutdown();
}

final class _FirstExportBlockingMetricExporter implements MetricExporter {
  final Completer<void> release = Completer<void>();
  final List<String> events = <String>[];
  int calls = 0;

  @override
  Future<ExportResult> export(List<MetricData> metrics) async {
    calls += 1;
    final call = calls;
    events.add('export$call-start');
    if (call == 1) {
      await release.future;
    }
    events.add('export$call-done');
    return ExportResult.success;
  }

  @override
  Future<void> forceFlush() async {}

  @override
  Future<void> shutdown() async {
    events.add('shutdown');
  }
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void defineExportResilienceTests() {
  group('export resilience', () {
    test('sync instruments drop non-finite measurements', () async {
      final h = _isolatedMeterProvider();
      final meter = h.provider.getMeter('m');
      final histogram = meter.createHistogram('h.nonfinite');
      final counter = meter.createDoubleCounter('c.nonfinite');

      histogram.record(1);
      histogram.record(double.nan);
      histogram.record(double.infinity);
      histogram.record(double.negativeInfinity);
      counter.add(2);
      counter.add(double.nan);
      counter.add(double.infinity);
      await h.reader.collect();

      final point = h.sink.lastMetricNamed('h.nonfinite')!.points.single;
      expect(point.count, 1);
      expect(point.sum, 1.0);
      expect(point.min, 1.0);
      expect(point.max, 1.0);
      expect(h.sink.lastMetricNamed('c.nonfinite')!.points.single.value, 2.0);
    });

    test('a NaN histogram measurement does not poison metric export', () async {
      final transport = _FakeOtlpHttpTransport();
      final exporter = OtlpHttpJsonMetricExporter(
        endpoint: 'https://collector.example.com',
        transport: transport,
        retry: const OtlpRetryConfig(maxAttempts: 1),
      );
      final h = _isolatedMeterProvider();
      final meter = h.provider.getMeter('m');
      meter.createHistogram('h.bad').record(double.nan);
      meter.createIntCounter('c.good').add(3);

      final result = await exporter.export(h.provider.collectAll());

      expect(result, ExportResult.success);
      final names = _jsonMetrics(
        _singleJsonBody(transport),
      ).map((metric) => metric['name']).toList();
      expect(names, contains('c.good'));
    });

    test(
      'non-finite gauge values are encoded as proto3 JSON strings',
      () async {
        final transport = _FakeOtlpHttpTransport();
        final exporter = OtlpHttpJsonMetricExporter(
          endpoint: 'https://collector.example.com',
          transport: transport,
          retry: const OtlpRetryConfig(maxAttempts: 1),
        );
        final h = _isolatedMeterProvider();
        final meter = h.provider.getMeter('m');
        meter.createObservableGauge('g.ok', callback: (r) => r.observe(1.5));
        meter.createObservableGauge(
          'g.special',
          callback: (r) {
            r.observe(double.nan, attributes: <String, Object>{'v': 'nan'});
            r.observe(
              double.infinity,
              attributes: <String, Object>{'v': 'inf'},
            );
            r.observe(
              double.negativeInfinity,
              attributes: <String, Object>{'v': '-inf'},
            );
          },
        );

        final result = await exporter.export(h.provider.collectAll());

        expect(result, ExportResult.success);
        final metrics = _jsonMetrics(_singleJsonBody(transport));
        Map<String, Object?> gauge(String name) =>
            metrics.singleWhere((m) => m['name'] == name)['gauge']
                as Map<String, Object?>;
        final ok = (gauge('g.ok')['dataPoints'] as List<Object?>).single;
        expect((ok as Map<String, Object?>)['asDouble'], 1.5);
        final special = (gauge('g.special')['dataPoints'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .map((point) => point['asDouble'])
            .toList();
        expect(special, <Object?>['NaN', 'Infinity', '-Infinity']);
      },
    );

    test('a NaN span attribute does not drop the span batch', () async {
      final transport = _FakeOtlpHttpTransport();
      final exporter = OtlpHttpJsonSpanExporter(
        endpoint: 'https://collector.example.com',
        transport: transport,
        retry: const OtlpRetryConfig(maxAttempts: 1),
      );
      final memory = InMemorySpanExporter();
      final tracer = TracerProvider(
        resource: Resource.empty(),
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(memory)],
        sampler: const AlwaysOnSampler(),
      ).getTracer('t');
      tracer.startSpan('ok').end();
      tracer
          .startSpan(
            'bad',
            attributes: <String, Object>{
              'ratio': double.nan,
              'bounds': <Object>[1.0, double.infinity, double.negativeInfinity],
            },
          )
          .end();
      await Future<void>.delayed(Duration.zero);

      final result = await exporter.export(memory.spans);

      expect(result, ExportResult.success);
      final payload = _singleJsonBody(transport);
      final spans =
          (((payload['resourceSpans'] as List<Object?>).single
                      as Map<String, Object?>)['scopeSpans']
                  as List<Object?>)
              .cast<Map<String, Object?>>()
              .expand(
                (scope) => (scope['spans'] as List<Object?>)
                    .cast<Map<String, Object?>>(),
              )
              .toList();
      expect(
        spans.map((span) => span['name']),
        containsAll(<String>['ok', 'bad']),
      );
      final bad = spans.singleWhere((span) => span['name'] == 'bad');
      final attributes = _decodeAttributes(bad['attributes'] as List<Object?>);
      expect(attributes['ratio'], 'NaN');
      expect(attributes['bounds'], <Object?>[1.0, 'Infinity', '-Infinity']);
    });
    test('a throwing observable callback does not block other metrics', () {
      final h = _isolatedMeterProvider();
      final meter = h.provider.getMeter('m');
      meter.createObservableGauge(
        'g.throws',
        callback: (_) => throw StateError('callback failed'),
      );
      meter.createIntCounter('c.after').add(1);
      meter.createObservableGauge('g.ok', callback: (r) => r.observe(2));

      final names = h.provider.collectAll().map((m) => m.name).toList();

      expect(names, <String>['c.after', 'g.ok']);
    });

    test('periodic reader never leaks collect errors to the zone', () async {
      final zoneErrors = <Object>[];
      final exporter = _ThrowingMetricExporter();
      final done = Completer<void>();
      runZonedGuarded(() async {
        final reader = PeriodicMetricReader(
          exporter: exporter,
          interval: const Duration(milliseconds: 20),
        );
        final provider = MeterProvider(
          resource: Resource.empty(),
          readers: <MetricReader>[reader],
        );
        final meter = provider.getMeter('m');
        meter.createObservableGauge(
          'g.throws',
          callback: (_) => throw StateError('callback failed'),
        );
        meter.createIntCounter('c.ok').add(1);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await reader.shutdown();
        done.complete();
      }, (error, _) => zoneErrors.add(error));
      // Errors cannot cross the guarded zone, so wait on a completer instead
      // of the zone's own future.
      await done.future.timeout(const Duration(seconds: 5));

      expect(zoneErrors, isEmpty);
      // A failed cycle must not stop later ticks from exporting.
      expect(exporter.exportCalls, greaterThan(1));
    });

    test('meter provider flushes every reader even if one throws', () async {
      final healthy = InMemoryMetricExporter();
      final provider = MeterProvider(
        resource: Resource.empty(),
        readers: <MetricReader>[
          ExportingMetricReader(exporter: _ThrowingMetricExporter()),
          ExportingMetricReader(exporter: healthy),
        ],
      );
      provider.getMeter('m').createIntCounter('c.flush').add(1);

      await provider.forceFlush();

      expect(healthy.lastMetricNamed('c.flush'), isNotNull);
      expect(healthy.forceFlushCount, 1);
    });

    test('Otel.forceFlush still flushes logs when metrics fail', () async {
      final logs = InMemoryLogExporter();
      final spans = InMemorySpanExporter();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'flush-isolation',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(spans)],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: _ThrowingMetricExporter()),
        ],
        logProcessors: <LogProcessor>[SimpleLogProcessor(logs)],
      );
      Otel.instance.meter.createIntCounter('c.any').add(1);

      await Otel.forceFlush();

      expect(spans.forceFlushCount, 1);
      expect(logs.forceFlushCount, 1);
    });
    test(
      'Retry-After above maxRetryAfter fails fast without retrying',
      () async {
        final transport = _SequencedOtlpHttpTransport(<Object>[
          const OtlpHttpResponse(
            statusCode: 503,
            headers: <String, String>{'retry-after': '3600'},
          ),
          const OtlpHttpResponse(statusCode: 200, body: '{}'),
        ]);
        // Default retry config: maxRetryAfter must default well below 3600 s.
        final exporter = OtlpHttpJsonSpanExporter(
          endpoint: 'https://collector.example.com',
          transport: transport,
        );

        final stopwatch = Stopwatch()..start();
        final result = await exporter
            .export(const <SpanData>[])
            .timeout(const Duration(seconds: 5));
        stopwatch.stop();

        // The server asked us to stay away: never resend earlier than that.
        expect(result, ExportResult.failure);
        expect(transport.requests, hasLength(1));
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );

    test('Retry-After above a custom maxRetryAfter fails fast', () async {
      final transport = _SequencedOtlpHttpTransport(<Object>[
        const OtlpHttpResponse(
          statusCode: 429,
          headers: <String, String>{'retry-after': '2'},
        ),
        const OtlpHttpResponse(statusCode: 200, body: '{}'),
      ]);
      final exporter = OtlpHttpJsonSpanExporter(
        endpoint: 'https://collector.example.com',
        transport: transport,
        retry: const OtlpRetryConfig(maxRetryAfter: Duration(seconds: 1)),
      );

      final result = await exporter
          .export(const <SpanData>[])
          .timeout(const Duration(seconds: 5));

      expect(result, ExportResult.failure);
      expect(transport.requests, hasLength(1));
    });
    test('a 2xx with an unparseable body is a success, not a retry', () async {
      const retry = OtlpRetryConfig(
        maxAttempts: 3,
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
      );
      final http = _SequencedOtlpHttpTransport(<Object>[
        for (var i = 0; i < 3; i++)
          const OtlpHttpResponse(statusCode: 200, body: '<html>portal</html>'),
      ]);
      final httpResult = await OtlpHttpJsonSpanExporter(
        endpoint: 'https://collector.example.com',
        transport: http,
        retry: retry,
      ).export(const <SpanData>[]);

      expect(httpResult, ExportResult.success);
      expect(http.requests, hasLength(1));

      final grpc = _SequencedOtlpGrpcTransport(<Object>[
        // Truncated partial_success message: the parser throws on it.
        for (var i = 0; i < 3; i++) <int>[0x0a, 0x05, 0x08],
      ]);
      final grpcResult = await OtlpGrpcSpanExporter(
        endpoint: 'http://collector.example.com:4317',
        transport: grpc,
        retry: retry,
      ).export(const <SpanData>[]);

      expect(grpcResult, ExportResult.success);
      expect(grpc.requests, hasLength(1));
    });
    test('periodic reader never runs two metric exports at once', () async {
      final exporter = _SlowMetricExporter(const Duration(milliseconds: 100));
      final reader = PeriodicMetricReader(
        exporter: exporter,
        interval: const Duration(milliseconds: 20),
      );
      final provider = MeterProvider(
        resource: Resource.empty(),
        readers: <MetricReader>[reader],
      );
      provider.getMeter('m').createIntCounter('c.overlap').add(1);

      await Future<void>.delayed(const Duration(milliseconds: 150));
      final callsBeforeFlush = exporter.calls;
      await Future.wait(<Future<void>>[
        provider.forceFlush(),
        provider.forceFlush(),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await reader.shutdown();

      expect(exporter.maxInFlight, 1);
      // forceFlush always runs a fresh export of its own.
      expect(exporter.calls, greaterThanOrEqualTo(callsBeforeFlush + 2));
    });
    test(
      'providers shut down every reader/processor even if one throws',
      () async {
        final failing = _ShutdownProbe()..throws = true;
        final reader = _ShutdownProbe();
        final span = _ShutdownProbe();
        final log = _ShutdownProbe();

        await MeterProvider(
          resource: Resource.empty(),
          readers: <MetricReader>[
            _ProbeMetricReader(failing),
            _ProbeMetricReader(reader),
          ],
        ).shutdown();
        await TracerProvider(
          resource: Resource.empty(),
          spanProcessors: <SpanProcessor>[
            _ProbeSpanProcessor(failing),
            _ProbeSpanProcessor(span),
          ],
          sampler: const AlwaysOnSampler(),
        ).shutdown();
        await LoggerProvider(
          resource: Resource.empty(),
          logProcessors: <LogProcessor>[
            _ProbeLogProcessor(failing),
            _ProbeLogProcessor(log),
          ],
        ).shutdown();

        expect(failing.shutdowns, 3);
        expect(reader.shutdowns, 1);
        expect(span.shutdowns, 1);
        expect(log.shutdowns, 1);
      },
    );

    test('Otel.shutdown shuts down every signal when one fails', () async {
      final span = _ShutdownProbe();
      final metrics = _ShutdownProbe()..throws = true;
      final log = _ShutdownProbe();
      await Otel.shutdown();
      await Otel.init(
        serviceName: 'shutdown-isolation',
        spanProcessors: <SpanProcessor>[_ProbeSpanProcessor(span)],
        metricReaders: <MetricReader>[_ProbeMetricReader(metrics)],
        logProcessors: <LogProcessor>[_ProbeLogProcessor(log)],
      );

      await Otel.shutdown();

      expect(span.shutdowns, 1);
      expect(metrics.shutdowns, 1);
      expect(log.shutdowns, 1);
      expect(Otel.isInitialized, isFalse);
    });
    test('Retry-After given as an HTTP-date is honored', () async {
      final header = formatHttpDate(
        DateTime.now().toUtc().add(const Duration(seconds: 2)),
      );
      final parsed = OtlpHttpResponse(
        statusCode: 503,
        headers: <String, String>{'retry-after': header},
      ).retryAfter;
      // HTTP-date has second precision, so up to 1 s is truncated.
      expect(parsed, isNotNull);
      expect(parsed!, greaterThan(const Duration(milliseconds: 900)));
      expect(parsed, lessThanOrEqualTo(const Duration(seconds: 2)));

      final transport = _SequencedOtlpHttpTransport(<Object>[
        OtlpHttpResponse(
          statusCode: 503,
          headers: <String, String>{
            'retry-after': formatHttpDate(
              DateTime.now().toUtc().add(const Duration(seconds: 2)),
            ),
          },
        ),
        const OtlpHttpResponse(statusCode: 200, body: '{}'),
      ]);
      final exporter = OtlpHttpJsonSpanExporter(
        endpoint: 'https://collector.example.com',
        transport: transport,
        retry: const OtlpRetryConfig(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
      );

      final stopwatch = Stopwatch()..start();
      final result = await exporter.export(const <SpanData>[]);
      stopwatch.stop();

      expect(result, ExportResult.success);
      expect(transport.requests, hasLength(2));
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 900)));
    });
    test('forceFlush waits a bounded time for a stuck export', () async {
      final exporter = _FirstExportBlockingMetricExporter();
      final reader = PeriodicMetricReader(
        exporter: exporter,
        interval: const Duration(milliseconds: 20),
        inFlightWaitLimit: const Duration(milliseconds: 200),
      );
      MeterProvider(
        resource: Resource.empty(),
        readers: <MetricReader>[reader],
      ).getMeter('m').createIntCounter('c.flush').add(1);
      await _waitFor(() => exporter.calls == 1);
      expect(exporter.calls, 1);

      final stopwatch = Stopwatch()..start();
      await reader.forceFlush().timeout(const Duration(seconds: 3));
      stopwatch.stop();

      // Waited for the stuck export up to the limit, then ran its own.
      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 150)));
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(exporter.events, contains('export2-done'));

      exporter.release.complete();
      await reader.shutdown();
    });
    test('shutdown lets an in-flight export finish before closing', () async {
      final exporter = _FirstExportBlockingMetricExporter();
      final reader = PeriodicMetricReader(
        exporter: exporter,
        interval: const Duration(milliseconds: 20),
        inFlightWaitLimit: const Duration(seconds: 2),
      );
      MeterProvider(
        resource: Resource.empty(),
        readers: <MetricReader>[reader],
      ).getMeter('m').createIntCounter('c.shutdown').add(1);
      await _waitFor(() => exporter.calls == 1);

      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 100),
          exporter.release.complete,
        ),
      );
      await reader.shutdown().timeout(const Duration(seconds: 3));

      expect(exporter.events, <String>[
        'export1-start',
        'export1-done',
        'shutdown',
      ]);
    });

    test('shutdown waits a bounded time for a stuck export', () async {
      final exporter = _FirstExportBlockingMetricExporter();
      final reader = PeriodicMetricReader(
        exporter: exporter,
        interval: const Duration(milliseconds: 20),
        inFlightWaitLimit: const Duration(milliseconds: 200),
      );
      MeterProvider(
        resource: Resource.empty(),
        readers: <MetricReader>[reader],
      ).getMeter('m').createIntCounter('c.stuck').add(1);
      await _waitFor(() => exporter.calls == 1);

      final stopwatch = Stopwatch()..start();
      await reader.shutdown().timeout(const Duration(seconds: 3));
      stopwatch.stop();

      expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 150)));
      expect(exporter.events.last, 'shutdown');
      exporter.release.complete();
    });
    test(
      'concurrent forceFlush on an idle reader exports one at a time',
      () async {
        final exporter = _SlowMetricExporter(const Duration(milliseconds: 100));
        final reader = PeriodicMetricReader(
          exporter: exporter,
          // No tick during the test: the reader is idle when both flushes start.
          interval: const Duration(hours: 1),
        );
        final provider = MeterProvider(
          resource: Resource.empty(),
          readers: <MetricReader>[reader],
        );
        provider.getMeter('m').createIntCounter('c.idle').add(1);

        await Future.wait(<Future<void>>[
          reader.forceFlush(),
          reader.forceFlush(),
        ]);
        await reader.shutdown();

        expect(exporter.calls, 2);
        expect(exporter.maxInFlight, 1);
      },
    );
  });
}
