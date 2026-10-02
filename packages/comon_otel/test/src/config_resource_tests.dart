part of '../comon_otel_test.dart';

void defineConfigAndResourceTests() {
  group('config and resources', () {
    test('reads OTEL env config and merges it into init defaults', () async {
      OtelEnvConfig.overrideEnvSource(
        () => <String, String>{
          'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://env-collector.example.com',
          'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT':
              'https://env-traces.example.com/v1/traces',
          'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json',
          'OTEL_EXPORTER_OTLP_TIMEOUT': '7000',
          'OTEL_EXPORTER_OTLP_TRACES_TIMEOUT': '1200',
          'OTEL_EXPORTER_OTLP_COMPRESSION': 'none',
          'OTEL_EXPORTER_OTLP_TRACES_COMPRESSION': 'gzip',
          'OTEL_EXPORTER_OTLP_HEADERS':
              'authorization=Bearer env,x-api-key=123',
          'OTEL_EXPORTER_OTLP_TRACES_HEADERS':
              'authorization=Bearer traces-env,x-trace-env=1',
          'OTEL_BSP_SCHEDULE_DELAY': '5000',
          'OTEL_BSP_EXPORT_TIMEOUT': '1500',
          'OTEL_BSP_MAX_QUEUE_SIZE': '1024',
          'OTEL_BSP_MAX_EXPORT_BATCH_SIZE': '64',
          'OTEL_BLRP_SCHEDULE_DELAY': '2500',
          'OTEL_BLRP_EXPORT_TIMEOUT': '1200',
          'OTEL_BLRP_MAX_QUEUE_SIZE': '256',
          'OTEL_BLRP_MAX_EXPORT_BATCH_SIZE': '32',
          'OTEL_METRIC_EXPORT_INTERVAL': '2000',
          'OTEL_METRIC_EXPORT_TIMEOUT': '1100',
          'OTEL_RESOURCE_ATTRIBUTES': 'deployment.region=eu,app.instance=blue',
          'OTEL_TRACES_SAMPLER': 'always_on',
          'OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT': '7',
          'OTEL_SPAN_EVENT_COUNT_LIMIT': '5',
          'OTEL_SPAN_LINK_COUNT_LIMIT': '3',
          'OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT': '2',
          'OTEL_LINK_ATTRIBUTE_COUNT_LIMIT': '4',
        },
      );

      final transport = _FakeOtlpHttpTransport();

      await Otel.shutdown();
      await Otel.init(serviceName: 'env-service', otlpTransport: transport);

      expect(
        Otel.instance.config.endpoint,
        'https://env-collector.example.com',
      );
      expect(
        Otel.instance.config.tracesEndpoint,
        'https://env-traces.example.com/v1/traces',
      );
      expect(Otel.instance.config.exporter, OtelExporter.otlpHttpJson);
      expect(Otel.instance.config.otlpHeaders['authorization'], 'Bearer env');
      expect(Otel.instance.config.otlpHeaders['x-api-key'], '123');
      expect(
        Otel.instance.config.otlpTracesHeaders['authorization'],
        'Bearer traces-env',
      );
      expect(Otel.instance.config.otlpTracesHeaders['x-api-key'], '123');
      expect(Otel.instance.config.otlpTracesHeaders['x-trace-env'], '1');
      expect(Otel.instance.config.otlpTimeout, const Duration(seconds: 7));
      expect(
        Otel.instance.config.otlpTracesTimeout,
        const Duration(milliseconds: 1200),
      );
      expect(
        Otel.instance.config.otlpMetricsTimeout,
        const Duration(seconds: 7),
      );
      expect(Otel.instance.config.otlpCompression, OtlpCompression.none);
      expect(Otel.instance.config.otlpTracesCompression, OtlpCompression.gzip);
      expect(Otel.instance.config.otlpMetricsCompression, OtlpCompression.none);
      expect(Otel.instance.config.useBatchSpanProcessor, isTrue);
      expect(
        Otel.instance.config.batchSpanProcessorScheduleDelay,
        const Duration(seconds: 5),
      );
      expect(
        Otel.instance.config.batchSpanProcessorExportTimeout,
        const Duration(milliseconds: 1500),
      );
      expect(Otel.instance.config.batchSpanProcessorMaxQueueSize, 1024);
      expect(Otel.instance.config.batchSpanProcessorMaxExportBatchSize, 64);
      expect(Otel.instance.config.useBatchLogProcessor, isTrue);
      expect(
        Otel.instance.config.batchLogProcessorScheduleDelay,
        const Duration(milliseconds: 2500),
      );
      expect(
        Otel.instance.config.batchLogProcessorExportTimeout,
        const Duration(milliseconds: 1200),
      );
      expect(Otel.instance.config.batchLogProcessorMaxQueueSize, 256);
      expect(Otel.instance.config.batchLogProcessorMaxExportBatchSize, 32);
      expect(Otel.instance.config.usePeriodicMetricReader, isTrue);
      expect(
        Otel.instance.config.metricExportInterval,
        const Duration(seconds: 2),
      );
      expect(
        Otel.instance.config.metricExportTimeout,
        const Duration(milliseconds: 1100),
      );
      expect(Otel.instance.config.spanLimits.attributeCountLimit, 7);
      expect(Otel.instance.config.spanLimits.eventCountLimit, 5);
      expect(Otel.instance.config.spanLimits.linkCountLimit, 3);
      expect(Otel.instance.config.spanLimits.attributePerEventCountLimit, 2);
      expect(Otel.instance.config.spanLimits.attributePerLinkCountLimit, 4);
      expect(
        Otel.instance.tracerProvider.resource.attributes['deployment.region'],
        'eu',
      );
      expect(
        Otel.instance.tracerProvider.resource.attributes['app.instance'],
        'blue',
      );

      await Otel.instance.tracer.traceAsync('env-span', fn: () async {});
      await Otel.forceFlush();
      while (transport.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      expect(
        transport.requests.single.request.uri.toString(),
        'https://env-traces.example.com/v1/traces',
      );
      expect(
        transport.requests.single.request.headers['content-encoding'],
        'gzip',
      );
      expect(
        transport.requests.single.request.headers['authorization'],
        'Bearer traces-env',
      );
      expect(transport.requests.single.request.headers['x-api-key'], '123');
      expect(transport.requests.single.request.headers['x-trace-env'], '1');
      expect(
        transport.requests.single.request.timeout,
        const Duration(milliseconds: 1200),
      );
    });

    test(
      'uses batch processors and a periodic metric reader when env config requests them',
      () async {
        OtelEnvConfig.overrideEnvSource(
          () => <String, String>{
            'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://env-batch.example.com',
            'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json',
            'OTEL_BSP_SCHEDULE_DELAY': '60000',
            'OTEL_BSP_MAX_EXPORT_BATCH_SIZE': '10',
            'OTEL_BLRP_SCHEDULE_DELAY': '60000',
            'OTEL_BLRP_MAX_EXPORT_BATCH_SIZE': '10',
            'OTEL_METRIC_EXPORT_INTERVAL': '20',
          },
        );

        final transport = _FakeOtlpHttpTransport();

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'env-batch-service',
          otlpTransport: transport,
        );

        final counter = Otel.instance.meter.createIntCounter('env.batch.count');
        await Otel.instance.tracer.traceAsync(
          'env-batch-span',
          fn: () async {
            counter.add(1);
            Otel.instance.logger.info('env-batch-log');
          },
        );

        expect(transport.requests, isEmpty);

        while (transport.requests.where((request) {
          return request.request.body.contains('resourceMetrics');
        }).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        final metricRequestsBeforeFlush = transport.requests.where((request) {
          return request.request.body.contains('resourceMetrics');
        }).length;
        final traceRequestsBeforeFlush = transport.requests.where((request) {
          return request.request.body.contains('resourceSpans');
        }).length;
        final logRequestsBeforeFlush = transport.requests.where((request) {
          return request.request.body.contains('resourceLogs');
        }).length;

        expect(metricRequestsBeforeFlush, greaterThanOrEqualTo(1));
        expect(traceRequestsBeforeFlush, 0);
        expect(logRequestsBeforeFlush, 0);

        await Otel.forceFlush();

        final traceRequestsAfterFlush = transport.requests.where((request) {
          return request.request.body.contains('resourceSpans');
        }).length;
        final logRequestsAfterFlush = transport.requests.where((request) {
          return request.request.body.contains('resourceLogs');
        }).length;

        expect(traceRequestsAfterFlush, 1);
        expect(logRequestsAfterFlush, 1);
      },
    );

    test(
      'init exposes batch and metric-reader configuration explicitly',
      () async {
        await Otel.shutdown();
        await Otel.init(
          serviceName: 'test-service',
          useBatchSpanProcessor: true,
          batchSpanProcessorScheduleDelay: const Duration(seconds: 2),
          batchSpanProcessorMaxQueueSize: 128,
          batchSpanProcessorMaxExportBatchSize: 64,
          useBatchLogProcessor: true,
          batchLogProcessorScheduleDelay: const Duration(seconds: 3),
          usePeriodicMetricReader: true,
          metricExportInterval: const Duration(seconds: 30),
        );

        final config = Otel.instance.config;
        expect(config.useBatchSpanProcessor, isTrue);
        expect(
          config.batchSpanProcessorScheduleDelay,
          const Duration(seconds: 2),
        );
        expect(config.batchSpanProcessorMaxQueueSize, 128);
        expect(config.batchSpanProcessorMaxExportBatchSize, 64);
        expect(config.useBatchLogProcessor, isTrue);
        expect(
          config.batchLogProcessorScheduleDelay,
          const Duration(seconds: 3),
        );
        expect(config.usePeriodicMetricReader, isTrue);
        expect(config.metricExportInterval, const Duration(seconds: 30));
      },
    );

    test(
      'default resource carries spec-mandatory telemetry.sdk attributes',
      () async {
        await Otel.shutdown();
        await Otel.init(serviceName: 'sdk-default-service');

        final attributes = Otel.instance.tracerProvider.resource.attributes;
        expect(attributes['telemetry.sdk.name'], 'comon_otel');
        expect(attributes['telemetry.sdk.language'], 'dart');
        expect(attributes['telemetry.sdk.version'], isNotEmpty);
      },
    );

    test(
      'explicit batch/periodic init params drive batch behavior (no env)',
      () async {
        final transport = _FakeOtlpHttpTransport();

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'explicit-batch-service',
          exporter: OtelExporter.otlpHttpJson,
          endpoint: 'https://explicit-batch.example.com',
          otlpTransport: transport,
          useBatchSpanProcessor: true,
          batchSpanProcessorScheduleDelay: const Duration(seconds: 60),
          batchSpanProcessorMaxExportBatchSize: 512,
          useBatchLogProcessor: true,
          batchLogProcessorScheduleDelay: const Duration(seconds: 60),
        );

        await Otel.instance.tracer.traceAsync(
          'explicit-batch-span',
          fn: () async {
            Otel.instance.logger.info('explicit-batch-log');
          },
        );

        // With a 60s schedule delay and batching ON, nothing is exported yet.
        expect(transport.requests, isEmpty);

        await Otel.forceFlush();

        // The http/json exporter has async beyond the flush-chain await, so
        // poll until the trace request lands (mirrors the existing
        // "reads OTEL env config" test, ~lines 119-123).
        while (transport.requests.where((request) {
          return request.request.body.contains('resourceSpans');
        }).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }

        final traceRequests = transport.requests.where((request) {
          return request.request.body.contains('resourceSpans');
        }).length;
        expect(traceRequests, greaterThanOrEqualTo(1));
      },
    );

    test('applies span limit env settings to runtime span behavior', () async {
      OtelEnvConfig.overrideEnvSource(
        () => <String, String>{
          'OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT': '1',
          'OTEL_SPAN_EVENT_COUNT_LIMIT': '1',
          'OTEL_SPAN_LINK_COUNT_LIMIT': '1',
          'OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT': '1',
          'OTEL_LINK_ATTRIBUTE_COUNT_LIMIT': '1',
        },
      );

      final envExporter = InMemorySpanExporter();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'env-span-limits',
        spanProcessors: <SpanProcessor>[SimpleSpanProcessor(envExporter)],
        metricReaders: <MetricReader>[
          ExportingMetricReader(exporter: metricExporter),
        ],
        logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
      );

      final span = Otel.instance.tracer.startSpan(
        'limited-span',
        attributes: <String, Object>{'first': 1, 'second': 2},
        links: <SpanLink>[
          SpanLink(
            context: SpanContext.local(
              traceId: const TraceId('11111111111111111111111111111111'),
              spanId: const SpanId('2222222222222222'),
              traceFlags: TraceFlags.sampled,
            ),
            attributes: <String, Object>{'a': 1, 'b': 2},
          ),
        ],
      );

      span.addEvent(
        'limited-event',
        attributes: <String, Object>{'a': 1, 'b': 2},
      );
      span.addLink(
        SpanLink(
          context: SpanContext.local(
            traceId: const TraceId('33333333333333333333333333333333'),
            spanId: const SpanId('4444444444444444'),
            traceFlags: TraceFlags.sampled,
          ),
        ),
      );
      await span.end();
      await Future<void>.delayed(Duration.zero);

      final exportedSpan = envExporter.lastSpanNamed('limited-span')!;
      // session.id is reserved (SessionSpanProcessor.onStart) — it always
      // survives the attribute limit alongside the one kept user attr.
      expect(exportedSpan.attributes.keys, <String>[
        'first',
        SemanticAttributes.sessionId,
      ]);
      expect(exportedSpan.events.single.attributes.keys, <String>['a']);
      expect(exportedSpan.links, hasLength(1));
      expect(exportedSpan.links.single.attributes.keys, <String>['a']);
      expect(exportedSpan.droppedAttributesCount, 3);
      expect(exportedSpan.droppedEventsCount, 0);
      expect(exportedSpan.droppedLinksCount, 1);
    });

    test(
      'supports OTEL_SDK_DISABLED and falls back to a default service name',
      () async {
        OtelEnvConfig.overrideEnvSource(
          () => <String, String>{
            'OTEL_SDK_DISABLED': 'true',
            'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://env-disabled.example.com',
            'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json',
          },
        );

        final transport = _FakeOtlpHttpTransport();

        await Otel.shutdown();
        await Otel.init(otlpTransport: transport);

        expect(Otel.instance.config.sdkDisabled, isTrue);
        expect(
          Otel.instance.tracerProvider.resource.attributes['service.name']
              as String,
          startsWith('unknown_service:'),
        );

        final span = Otel.instance.tracer.startSpan('disabled-span');
        expect(span.isRecording, isFalse);

        Otel.instance.meter.createIntCounter('disabled.counter').add(1);
        Otel.instance.logger.info('disabled-log');
        await span.end();
        await Otel.forceFlush();

        expect(transport.requests, isEmpty);
      },
    );

    test('configures the global propagator from OTEL_PROPAGATORS', () async {
      OtelEnvConfig.overrideEnvSource(
        () => <String, String>{'OTEL_PROPAGATORS': 'b3,baggage'},
      );

      await Otel.shutdown();
      await Otel.init(serviceName: 'propagator-env-service');

      final carrier = <String, String>{};
      final snapshot = OtelContextSnapshot.remote(
        traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
        spanId: const SpanId('00f067aa0ba902b7'),
        traceFlags: TraceFlags.sampled,
        baggage: Baggage.empty().withEntry('tenant.id', 'acme'),
      );

      Otel.propagator.inject(snapshot, carrier);

      expect(carrier['b3'], isNotNull);
      expect(carrier['baggage'], 'tenant.id=acme');
      expect(carrier.containsKey('traceparent'), isFalse);
    });

    test(
      'uses W3C trace-context and baggage as the default global propagator',
      () async {
        await Otel.shutdown();
        await Otel.init(serviceName: 'propagator-default-service');

        final carrier = <String, String>{};
        final snapshot = OtelContextSnapshot.remote(
          traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
          spanId: const SpanId('00f067aa0ba902b7'),
          traceFlags: TraceFlags.sampled,
          baggage: Baggage.empty().withEntry('tenant.id', 'acme'),
        );

        Otel.propagator.inject(snapshot, carrier);

        expect(carrier['traceparent'], isNotNull);
        expect(carrier['baggage'], 'tenant.id=acme');
        expect(carrier.containsKey('b3'), isFalse);
      },
    );

    test(
      'exposes APIs for overriding and resetting the global propagator',
      () async {
        await Otel.shutdown();
        await Otel.init(serviceName: 'propagator-api-service');

        final snapshot = OtelContextSnapshot.remote(
          traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
          spanId: const SpanId('00f067aa0ba902b7'),
          traceFlags: TraceFlags.sampled,
        );
        final b3Carrier = <String, String>{};
        final w3cCarrier = <String, String>{};

        Otel.setPropagator(const B3Propagator(useSingleHeader: true));
        Otel.propagator.inject(snapshot, b3Carrier);

        Otel.resetPropagator();
        Otel.propagator.inject(snapshot, w3cCarrier);

        expect(b3Carrier['b3'], isNotNull);
        expect(b3Carrier.containsKey('traceparent'), isFalse);
        expect(w3cCarrier['traceparent'], isNotNull);
      },
    );

    test('reads http/protobuf OTEL env protocol', () async {
      OtelEnvConfig.overrideEnvSource(
        () => <String, String>{
          'OTEL_EXPORTER_OTLP_ENDPOINT': 'https://env-protobuf.example.com',
          'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/protobuf',
        },
      );

      final transport = _FakeOtlpHttpTransport();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'env-http-protobuf',
        otlpTransport: transport,
      );

      expect(Otel.instance.config.exporter, OtelExporter.otlpHttp);

      await Otel.instance.tracer.traceAsync(
        'env-http-protobuf-span',
        fn: () async {},
      );
      await Otel.forceFlush();

      expect(
        transport.requests.single.request.headers['content-type'],
        'application/x-protobuf',
      );
    });

    test('reads grpc OTEL env protocol', () async {
      OtelEnvConfig.overrideEnvSource(
        () => <String, String>{
          'OTEL_EXPORTER_OTLP_ENDPOINT': 'http://env-grpc.example.com:4317',
          'OTEL_EXPORTER_OTLP_PROTOCOL': 'grpc',
        },
      );

      final transport = _FakeOtlpGrpcTransport();

      await Otel.shutdown();
      await Otel.init(serviceName: 'env-grpc', otlpGrpcTransport: transport);

      expect(Otel.instance.config.exporter, OtelExporter.otlpGrpc);

      await Otel.instance.tracer.traceAsync('env-grpc-span', fn: () async {});
      await Otel.forceFlush();

      expect(transport.requests.single.request.signal, OtlpSignal.traces);
    });

    test('compresses OTLP JSON payloads with gzip when configured', () async {
      final transport = _FakeOtlpHttpTransport();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'gzip-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpCompression: OtlpCompression.gzip,
        otlpTransport: transport,
      );

      await Otel.instance.tracer.traceAsync('gzip-span', fn: () async {});
      await Otel.forceFlush();

      final traceRequest = transport.requests
          .firstWhere((request) => request.request.uri.path == '/v1/traces')
          .request;
      final decodedBody = utf8.decode(gzip.decode(traceRequest.bodyBytes));

      expect(traceRequest.headers['content-encoding'], 'gzip');
      expect(decodedBody, contains('resourceSpans'));
    });

    test('exposes expanded semantic attribute constants', () {
      expect(SemanticAttributes.httpMethod, 'http.request.method');
      expect(SemanticAttributes.dbStatement, 'db.statement');
      expect(SemanticAttributes.rpcMethod, 'rpc.method');
      expect(SemanticAttributes.flutterRoute, 'flutter.route');
      expect(SemanticAttributes.appLifecycleState, 'app.lifecycle.state');
    });

    test('supports empty resources and default resource detection', () {
      expect(Resource.empty().attributes, isEmpty);

      final resource = Resource.autoDetect(serviceName: 'detected-service');

      expect(resource.attributes['service.name'], 'detected-service');
      expect(resource.attributes['process.runtime.name'], 'dart');
      expect(resource.attributes['process.pid'], pid);
      expect(resource.attributes['os.type'], Platform.operatingSystem);
      expect(resource.attributes['process.executable.name'], isNotNull);
    });

    test(
      'allows custom resource detectors and keeps explicit attributes last',
      () {
        final resource = Resource.autoDetect(
          serviceName: 'custom-detected-service',
          detectors: <ResourceDetector>[
            _StaticResourceDetector(<String, Object>{
              'host.name': 'detector-host',
              'deployment.environment': 'detector-env',
            }),
          ],
          environment: 'explicit-env',
          extra: <String, Object>{'service.version': '1.2.3'},
        );

        expect(resource.attributes['host.name'], 'detector-host');
        expect(resource.attributes['deployment.environment'], 'explicit-env');
        expect(resource.attributes['service.version'], '1.2.3');
      },
    );

    test(
      'omitting HostResourceDetector keeps host.name out of the resource',
      () async {
        await Otel.shutdown();
        await Otel.init(
          serviceName: 'pii-test',
          serviceVersion: '1.2.3',
          resourceDetectors: const <ResourceDetector>[
            ProcessResourceDetector(),
            TelemetrySdkResourceDetector(),
          ],
        );

        final attributes = Otel.instance.tracerProvider.resource.attributes;
        expect(attributes.containsKey('host.name'), isFalse);
        expect(attributes['service.version'], '1.2.3');
        expect(attributes['telemetry.sdk.name'], 'comon_otel');
        expect(attributes['telemetry.sdk.language'], 'dart');
        expect(attributes['telemetry.sdk.version'], isNotEmpty);
      },
    );

    test('explicit serviceVersion wins over a detector emitting it', () {
      final resource = Resource.autoDetect(
        serviceName: 'svc',
        serviceVersion: '2.0.0',
        detectors: <ResourceDetector>[
          _StaticResourceDetector(<String, Object>{
            'service.version': 'detector-version',
          }),
        ],
      );

      expect(resource.attributes['service.version'], '2.0.0');
    });

    test('preserves resource schemaUrl through bootstrap and merge', () {
      expect(Resource.empty().schemaUrl, isNull);

      final resource = Resource.autoDetect(
        serviceName: 'schema-resource-service',
        schemaUrl: 'https://opentelemetry.io/schemas/1.28.0',
      );

      expect(resource.schemaUrl, 'https://opentelemetry.io/schemas/1.28.0');

      final merged = resource.merge(
        Resource(
          serviceName: 'schema-resource-service',
          schemaUrl: 'https://opentelemetry.io/schemas/1.29.0',
          extra: const <String, Object>{'service.version': '1.0.0'},
        ),
      );

      expect(merged.schemaUrl, 'https://opentelemetry.io/schemas/1.29.0');
      expect(merged.attributes['service.version'], '1.0.0');
    });

    test('encodes histogram metrics as OTLP histogram payloads', () async {
      final transport = _FakeOtlpHttpTransport();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'histogram-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpTransport: transport,
      );

      final histogram = Otel.instance.meter.createHistogram('latency.ms');
      histogram.record(12.5);
      histogram.record(20.0);

      await Otel.forceFlush();
      while (transport.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final metricPayload =
          jsonDecode(
                transport.requests
                    .firstWhere(
                      (request) => request.request.uri.path == '/v1/metrics',
                    )
                    .request
                    .body,
              )
              as Map<String, Object?>;
      final resourceMetrics = metricPayload['resourceMetrics'] as List<Object?>;
      final metrics =
          ((((resourceMetrics.single as Map<String, Object?>)['scopeMetrics']
                          as List<Object?>)
                      .single
                  as Map<String, Object?>)['metrics']
              as List<Object?>);
      final latencyMetric = metrics.single as Map<String, Object?>;
      final histogramPayload =
          latencyMetric['histogram'] as Map<String, Object?>;
      final dataPoint =
          (histogramPayload['dataPoints'] as List<Object?>).single
              as Map<String, Object?>;

      expect(dataPoint['count'], 2);
      expect(dataPoint['min'], 12.5);
      expect(dataPoint['max'], 20.0);
      expect(dataPoint['sum'], 32.5);
      expect(dataPoint['explicitBounds'], isEmpty);
      expect(dataPoint['bucketCounts'], <int>[2]);
    });

    test('aggregates counters cumulatively by attribute set', () async {
      final counter = Otel.instance.meter.createIntCounter('agg.counter');

      counter.add(2, attributes: <String, Object>{'route': '/users'});
      counter.add(5, attributes: <String, Object>{'route': '/users'});
      counter.add(1, attributes: <String, Object>{'route': '/orders'});

      await Otel.forceFlush();

      final metric = metricExporter.lastMetricNamed('agg.counter');
      expect(metric, isNotNull);
      expect(metric!.points, hasLength(2));

      final usersPoint = metric.points.firstWhere(
        (point) => point.attributes['route'] == '/users',
      );
      final ordersPoint = metric.points.firstWhere(
        (point) => point.attributes['route'] == '/orders',
      );

      expect(usersPoint.value, 7);
      expect(usersPoint.startTimestamp, isNotNull);
      expect(ordersPoint.value, 1);
    });

    test(
      'limits synchronous metric cardinality and aggregates overflow series',
      () async {
        await Otel.shutdown();
        await Otel.init(
          serviceName: 'metric-cardinality-test',
          spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
          metricReaders: <MetricReader>[
            ExportingMetricReader(exporter: metricExporter),
          ],
          logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
          metricCardinalityLimit: 2,
        );

        final counter = Otel.instance.meter.createIntCounter('limited.counter');

        counter.add(1, attributes: <String, Object>{'route': '/users'});
        counter.add(2, attributes: <String, Object>{'route': '/orders'});
        counter.add(3, attributes: <String, Object>{'route': '/products'});

        await Otel.forceFlush();

        var metric = metricExporter.lastMetricNamed('limited.counter');
        expect(metric, isNotNull);
        expect(metric!.points, hasLength(3));

        final firstOverflowPoint = metric.points.singleWhere(
          (point) => point.attributes['otel.metric.overflow'] == true,
        );
        expect(firstOverflowPoint.value, 3);

        metricExporter.clear();
        counter.add(4, attributes: <String, Object>{'route': '/admin'});

        await Otel.forceFlush();

        metric = metricExporter.lastMetricNamed('limited.counter');
        expect(metric, isNotNull);
        expect(metric!.points, hasLength(3));

        final usersPoint = metric.points.firstWhere(
          (point) => point.attributes['route'] == '/users',
        );
        final ordersPoint = metric.points.firstWhere(
          (point) => point.attributes['route'] == '/orders',
        );
        final overflowPoint = metric.points.singleWhere(
          (point) => point.attributes['otel.metric.overflow'] == true,
        );

        expect(usersPoint.value, 1);
        expect(ordersPoint.value, 2);
        expect(overflowPoint.value, 7);
      },
    );

    test(
      'limits observable metric cardinality using first-observed attribute sets',
      () async {
        await Otel.shutdown();
        await Otel.init(
          serviceName: 'observable-cardinality-test',
          spanProcessors: <SpanProcessor>[SimpleSpanProcessor(exporter)],
          metricReaders: <MetricReader>[
            ExportingMetricReader(exporter: metricExporter),
          ],
          logProcessors: <LogProcessor>[SimpleLogProcessor(logExporter)],
          metricCardinalityLimit: 2,
        );

        Otel.instance.meter.createObservableCounter(
          'limited.observable.counter',
          callback: (result) {
            result.observe(1, attributes: <String, Object>{'route': '/users'});
            result.observe(2, attributes: <String, Object>{'route': '/orders'});
            result.observe(
              3,
              attributes: <String, Object>{'route': '/products'},
            );
          },
        );

        await Otel.forceFlush();

        final metric = metricExporter.lastMetricNamed(
          'limited.observable.counter',
        );
        expect(metric, isNotNull);
        expect(metric!.points, hasLength(3));

        final usersPoint = metric.points.firstWhere(
          (point) => point.attributes['route'] == '/users',
        );
        final ordersPoint = metric.points.firstWhere(
          (point) => point.attributes['route'] == '/orders',
        );
        final overflowPoint = metric.points.singleWhere(
          (point) => point.attributes['otel.metric.overflow'] == true,
        );

        expect(usersPoint.value, 1);
        expect(ordersPoint.value, 2);
        expect(overflowPoint.value, 3);
      },
    );

    test(
      'preserves histogram boundaries in aggregated metric points',
      () async {
        final histogram = Otel.instance.meter.createHistogram(
          'agg.histogram',
          boundaries: <double>[10, 20],
        );

        histogram.record(5.0, attributes: <String, Object>{'route': '/users'});
        histogram.record(15.0, attributes: <String, Object>{'route': '/users'});
        histogram.record(30.0, attributes: <String, Object>{'route': '/users'});

        await Otel.forceFlush();

        final metric = metricExporter.lastMetricNamed('agg.histogram');
        expect(metric, isNotNull);
        final point = metric!.points.single;
        expect(point.count, 3);
        expect(point.sum, 50.0);
        expect(point.min, 5.0);
        expect(point.max, 30.0);
        expect(point.explicitBounds, <double>[10, 20]);
        expect(point.bucketCounts, <int>[1, 1, 1]);
      },
    );

    test('adds the default user-agent header to OTLP HTTP requests', () async {
      final transport = _FakeOtlpHttpTransport();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'http-user-agent-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpTransport: transport,
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      await Otel.instance.tracer.traceAsync(
        'http-user-agent-span',
        fn: () async {},
      );
      await Otel.forceFlush();

      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.request.headers['user-agent'],
        defaultOtlpUserAgent,
      );
    });

    test(
      'preserves an explicit OTLP HTTP user-agent header regardless of casing',
      () async {
        final transport = _FakeOtlpHttpTransport();

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'http-custom-user-agent-test',
          endpoint: 'https://collector.example.com',
          exporter: OtelExporter.otlpHttpJson,
          otlpTransport: transport,
          otlpHeaders: const <String, String>{
            'User-Agent': 'custom-http-agent',
          },
          metricReaders: const <MetricReader>[],
          logProcessors: const <LogProcessor>[],
        );

        await Otel.instance.tracer.traceAsync(
          'http-custom-user-agent-span',
          fn: () async {},
        );
        await Otel.forceFlush();

        final headers = transport.requests.single.request.headers;
        expect(headers, containsPair('User-Agent', 'custom-http-agent'));
        expect(
          headers.keys.where((key) => key.toLowerCase() == 'user-agent'),
          hasLength(1),
        );
      },
    );

    test('adds the default user-agent header to OTLP gRPC requests', () async {
      final transport = _FakeOtlpGrpcTransport();

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'grpc-user-agent-test',
        endpoint: 'http://collector.example.com:4317',
        exporter: OtelExporter.otlpGrpc,
        otlpGrpcTransport: transport,
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      await Otel.instance.tracer.traceAsync(
        'grpc-user-agent-span',
        fn: () async {},
      );
      await Otel.forceFlush();

      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.request.headers['user-agent'],
        defaultOtlpUserAgent,
      );
    });

    test(
      'preserves an explicit OTLP gRPC user-agent header regardless of casing',
      () async {
        final transport = _FakeOtlpGrpcTransport();

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'grpc-custom-user-agent-test',
          endpoint: 'http://collector.example.com:4317',
          exporter: OtelExporter.otlpGrpc,
          otlpGrpcTransport: transport,
          otlpHeaders: const <String, String>{
            'User-Agent': 'custom-grpc-agent',
          },
          metricReaders: const <MetricReader>[],
          logProcessors: const <LogProcessor>[],
        );

        await Otel.instance.tracer.traceAsync(
          'grpc-custom-user-agent-span',
          fn: () async {},
        );
        await Otel.forceFlush();

        final headers = transport.requests.single.request.headers;
        expect(headers, containsPair('User-Agent', 'custom-grpc-agent'));
        expect(
          headers.keys.where((key) => key.toLowerCase() == 'user-agent'),
          hasLength(1),
        );
      },
    );

    test(
      'applies OTLP HTTP per-signal retry overrides over shared retry',
      () async {
        final transport = _SignalAwareOtlpHttpTransport(<String, List<Object>>{
          'traces': <Object>[
            const OtlpHttpResponse(statusCode: 503, body: 'retry traces'),
            const OtlpHttpResponse(statusCode: 200, body: '{}'),
          ],
          'metrics': <Object>[
            const OtlpHttpResponse(statusCode: 503, body: 'fail metrics'),
          ],
          'logs': <Object>[
            const OtlpHttpResponse(statusCode: 503, body: 'fail logs'),
          ],
        });

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'http-signal-retry-test',
          endpoint: 'https://collector.example.com',
          exporter: OtelExporter.otlpHttpJson,
          otlpTransport: transport,
          otlpRetry: const OtlpRetryConfig(
            maxAttempts: 1,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
          otlpTracesRetry: const OtlpRetryConfig(
            maxAttempts: 2,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
        );

        final counter = Otel.instance.meter.createIntCounter(
          'http.retry.count',
        );
        await Otel.instance.tracer.traceAsync(
          'http-signal-retry-span',
          fn: () async {
            counter.add(1);
            Otel.instance.logger.info('http-signal-retry-log');
          },
        );
        await Otel.forceFlush();

        expect(
          transport.requests.where(
            (request) => request.request.body.contains('resourceSpans'),
          ),
          hasLength(2),
        );
        expect(
          transport.requests.where(
            (request) => request.request.body.contains('resourceMetrics'),
          ),
          hasLength(1),
        );
        expect(
          transport.requests.where(
            (request) => request.request.body.contains('resourceLogs'),
          ),
          hasLength(1),
        );
      },
    );

    test(
      'applies OTLP gRPC per-signal retry overrides over shared retry',
      () async {
        final transport = _SignalAwareOtlpGrpcTransport(
          <OtlpSignal, List<Object>>{
            OtlpSignal.traces: <Object>[
              const OtlpGrpcTransportException('retry traces', retryable: true),
              const Object(),
            ],
            OtlpSignal.metrics: <Object>[
              const OtlpGrpcTransportException('fail metrics', retryable: true),
            ],
            OtlpSignal.logs: <Object>[
              const OtlpGrpcTransportException('fail logs', retryable: true),
            ],
          },
        );

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'grpc-signal-retry-test',
          endpoint: 'http://collector.example.com:4317',
          exporter: OtelExporter.otlpGrpc,
          otlpGrpcTransport: transport,
          otlpRetry: const OtlpRetryConfig(
            maxAttempts: 1,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
          otlpTracesRetry: const OtlpRetryConfig(
            maxAttempts: 2,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
        );

        final counter = Otel.instance.meter.createIntCounter(
          'grpc.retry.count',
        );
        await Otel.instance.tracer.traceAsync(
          'grpc-signal-retry-span',
          fn: () async {
            counter.add(1);
            Otel.instance.logger.info('grpc-signal-retry-log');
          },
        );
        await Otel.forceFlush();

        expect(
          transport.requests.where(
            (request) => request.request.signal == OtlpSignal.traces,
          ),
          hasLength(2),
        );
        expect(
          transport.requests.where(
            (request) => request.request.signal == OtlpSignal.metrics,
          ),
          hasLength(1),
        );
        expect(
          transport.requests.where(
            (request) => request.request.signal == OtlpSignal.logs,
          ),
          hasLength(1),
        );
      },
    );

    test('retries OTLP exports on retryable responses', () async {
      final transport = _SequencedOtlpHttpTransport(<Object>[
        const OtlpHttpResponse(statusCode: 503, body: 'unavailable'),
        const OtlpHttpResponse(statusCode: 200, body: '{}'),
      ]);

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'retry-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpTransport: transport,
        otlpRetry: const OtlpRetryConfig(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      await Otel.instance.tracer.traceAsync('retry-span', fn: () async {});
      await Future<void>.delayed(Duration.zero);

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.every(
          (request) => request.request.uri.path == '/v1/traces',
        ),
        isTrue,
      );
    });

    test('honors Retry-After for OTLP HTTP throttling responses', () async {
      final transport = _SequencedOtlpHttpTransport(<Object>[
        const OtlpHttpResponse(
          statusCode: 429,
          body: 'throttled',
          headers: <String, String>{'retry-after': '1'},
        ),
        const OtlpHttpResponse(statusCode: 200, body: '{}'),
      ]);

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'retry-after-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpTransport: transport,
        // Retry-After is honored as sent (up to maxRetryAfter), independent
        // of the backoff maxDelay.
        otlpRetry: const OtlpRetryConfig(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          backoffMultiplier: 1,
          maxDelay: Duration.zero,
        ),
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      final stopwatch = Stopwatch()..start();
      await Otel.instance.tracer.traceAsync(
        'retry-after-span',
        fn: () async {},
      );
      await Otel.forceFlush();
      stopwatch.stop();

      expect(transport.requests, hasLength(2));
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 950)),
      );
    });

    test('does not retry OTLP HTTP JSON partial success responses', () async {
      final transport = _SequencedOtlpHttpTransport(<Object>[
        const OtlpHttpResponse(
          statusCode: 200,
          body:
              '{"partialSuccess":{"rejectedSpans":1,"errorMessage":"drop invalid span"}}',
        ),
      ]);

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'json-partial-success-test',
        endpoint: 'https://collector.example.com',
        exporter: OtelExporter.otlpHttpJson,
        otlpTransport: transport,
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
        otlpRetry: const OtlpRetryConfig(
          maxAttempts: 3,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
      );

      await Otel.instance.tracer.traceAsync(
        'json-partial-success-span',
        fn: () async {},
      );
      await Otel.forceFlush();

      expect(transport.requests, hasLength(1));
    });

    test(
      'does not retry OTLP HTTP protobuf partial success responses',
      () async {
        final responseBytes = _encodePartialSuccessResponse(
          rejectedCount: 2,
          errorMessage: 'drop invalid telemetry',
        );
        final transport = _SequencedOtlpHttpTransport(<Object>[
          OtlpHttpResponse(
            statusCode: 200,
            body: String.fromCharCodes(responseBytes),
            rawBody: responseBytes,
          ),
        ]);

        await Otel.shutdown();
        await Otel.init(
          serviceName: 'protobuf-partial-success-test',
          endpoint: 'https://collector.example.com',
          exporter: OtelExporter.otlpHttp,
          otlpTransport: transport,
          metricReaders: const <MetricReader>[],
          logProcessors: const <LogProcessor>[],
          otlpRetry: const OtlpRetryConfig(
            maxAttempts: 3,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
        );

        await Otel.instance.tracer.traceAsync(
          'protobuf-partial-success-span',
          fn: () async {},
        );
        await Otel.forceFlush();

        expect(transport.requests, hasLength(1));
      },
    );

    test('retries OTLP gRPC exports on retryable transport failures', () async {
      final transport = _SequencedOtlpGrpcTransport(<Object>[
        const OtlpGrpcTransportException(
          'temporary unavailable',
          retryable: true,
        ),
        const Object(),
      ]);

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'grpc-retry-test',
        endpoint: 'http://collector.example.com:4317',
        exporter: OtelExporter.otlpGrpc,
        otlpGrpcTransport: transport,
        otlpRetry: const OtlpRetryConfig(
          maxAttempts: 2,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
      );

      await Otel.instance.tracer.traceAsync('grpc-retry-span', fn: () async {});
      await Future<void>.delayed(Duration.zero);

      expect(transport.requests, hasLength(2));
      expect(
        transport.requests.every(
          (request) => request.request.signal == OtlpSignal.traces,
        ),
        isTrue,
      );
    });

    test('does not retry OTLP gRPC partial success responses', () async {
      final responseBytes = _encodePartialSuccessResponse(
        rejectedCount: 1,
        errorMessage: 'drop invalid telemetry',
      );
      final transport = _SequencedOtlpGrpcTransport(<Object>[responseBytes]);

      await Otel.shutdown();
      await Otel.init(
        serviceName: 'grpc-partial-success-test',
        endpoint: 'http://collector.example.com:4317',
        exporter: OtelExporter.otlpGrpc,
        otlpGrpcTransport: transport,
        metricReaders: const <MetricReader>[],
        logProcessors: const <LogProcessor>[],
        otlpRetry: const OtlpRetryConfig(
          maxAttempts: 3,
          initialDelay: Duration.zero,
          maxDelay: Duration.zero,
        ),
      );

      await Otel.instance.tracer.traceAsync(
        'grpc-partial-success-span',
        fn: () async {},
      );
      await Otel.forceFlush();

      expect(transport.requests, hasLength(1));
    });
  });
}
