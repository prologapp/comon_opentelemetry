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
  });
}
