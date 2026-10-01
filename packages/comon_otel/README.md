# comon_otel

OpenTelemetry SDK foundation for Dart with traces, metrics, logs, propagation,
and OTLP exporters behind a single public entrypoint.

This package lives in the monorepo at `packages/comon_otel`.

## Features

- `Otel.init()` bootstrap
- zone-based active span propagation
- `TracerProvider`, `Tracer`, `Span`, `SpanContext`, and `SpanLink`
- `MeterProvider`, `Meter`, counters, histograms, and observable instruments
- `LoggerProvider`, `OtelLogger`, and log processors
- W3C trace-context propagation, W3C baggage, B3, and composite propagators
- Baggage storage in zone context
- sync and async tracing helpers
- function extensions for ergonomic tracing
- console exporters for traces, metrics, and logs
- in-memory exporters for tests
- OTLP HTTP JSON, OTLP HTTP/protobuf, and OTLP gRPC exporters

## Installation

```bash
dart pub add comon_otel
```

## Quick Start

```dart
import 'package:comon_otel/comon_otel.dart';

Future<void> main() async {
	await Otel.init(
		serviceName: 'my-app',
		exporter: OtelExporter.console,
	);

	final requests = Otel.instance.meter.createIntCounter('requests.total');

	final userId = await Otel.instance.tracer.traceAsync<String>(
		'load-user',
		fn: () async {
			requests.add(1, attributes: const <String, Object>{'route': '/user'});
			Otel.instance.logger.info('Loading user');
			return '42';
		},
	);

	await Otel.shutdown();
	print('Loaded user: $userId');
}
```

## Scope

`0.0.1-alpha.1` is intended as a foundation alpha for Dart services and libraries.

Supported in this alpha:

- traces
- metrics
- logs
- instrumentation scope metadata on tracer and meter acquisition, exported span and metric models, and OTLP payloads
- basic metric cardinality limiting with overflow aggregation for sync and async instruments
- context propagation with W3C trace-context, W3C baggage, B3, and composite propagators
- OTLP HTTP JSON exporters
- OTLP HTTP/protobuf exporters
- OTLP gRPC exporters
- batching, periodic metric reads, in-memory testing helpers, and collector-backed integration coverage

What this alpha is for:

- validating public API direction
- validating OTLP transport behavior against a real collector
- letting early adopters instrument Dart services and internal libraries

Not yet claimed in this alpha:

- full OpenTelemetry specification coverage
- finalized long-term API stability
- complete production bootstrap from environment variables alone

## Configuration

`Otel.init(...)` gives you a compact programmatic surface for the most common
setup tasks:

- `serviceName`
- `exporter`
- `endpoint`
- `resource`
- `spanProcessors`
- `metricReaders`
- `logProcessors`
- `sampler`
- `spanLimits`

The package also supports environment-driven bootstrap for a useful subset of
`OTEL_*` settings, described later in the `Environment Variables` section.

## Known Limitations

Known gaps that are intentionally still open after this alpha:

- environment bootstrap is partial: some `OTEL_*` settings are implemented, but not the full expected env surface yet
- default resource detection is intentionally minimal and currently focuses on process, runtime, OS, and host basics
- metric cardinality limiting is currently basic: it is configured only at the `MeterProvider`/`Otel.init(...)` level, not per reader or via Views
- OTLP spec fidelity still has gaps around advanced exporter configurability and some exporter contract details
- views, exemplars, Prometheus, Zipkin, declarative configuration, and compatibility layers are intentionally out of scope for `0.0.1-alpha.1`

## Bootstrap Defaults

The package now exposes a global propagator registry through `Otel.propagator`, `Otel.setPropagator(...)`, and `Otel.resetPropagator()`.

Default behavior:

- `Otel.init()` installs a default composite propagator with W3C trace-context and W3C baggage
- `OTEL_PROPAGATORS` can override the global propagator during init
- supported env propagator values are `tracecontext`, `baggage`, `b3`, `b3multi`, and `none`
- `OTEL_SDK_DISABLED=true` disables telemetry export and switches tracing to non-recording spans
- when `serviceName` is omitted and `OTEL_SERVICE_NAME` is not set, the SDK falls back to `unknown_service:<runtime>`
- `Resource.autoDetect(...)` now applies minimal built-in process and host detectors, and also accepts custom `ResourceDetector` implementations
- `Otel.init(metricCardinalityLimit: ...)` applies a default per-instrument metric series cap and routes excess attribute sets into an overflow series with `otel.metric.overflow=true`

## Public Entry Point

The package exposes a single public entry point:

```dart
import 'package:comon_otel/comon_otel.dart';
```

Internally, the package uses a single source aggregator at `lib/src/comon_otel.dart`.
Each `src/*` directory with multiple files exposes its own local barrel file, and that internal aggregator re-exports those folder-level barrels.

## Propagation

```dart
final carrier = <String, String>{};

await Otel.instance.tracer.traceAsync('request', fn: () async {
	final baggage = Baggage.empty().withEntry('tenant.id', 'acme');
	OtelContext.withBaggage(baggage, () {
		const CompositePropagator(<TextMapPropagator>[
			W3CTraceContextPropagator(),
			W3CBaggagePropagator(),
		]).inject(OtelContext.current, carrier);
	});
});

final extracted = const W3CTraceContextPropagator().extract(carrier);
final child = Otel.instance.tracer.startSpan(
	'downstream',
	parentContext: extracted.spanContext,
);
await child.end();

final manualRemote = OtelContextSnapshot.remote(
	traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
	spanId: const SpanId('00f067aa0ba902b7'),
	traceFlags: TraceFlags.sampled,
	traceState: const TraceState('vendor=value'),
);

const W3CTraceContextPropagator().inject(manualRemote, carrier);
```

## Span Links

```dart
final link = SpanLink(
	context: SpanContext.local(
		traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
		spanId: const SpanId('00f067aa0ba902b7'),
		traceFlags: TraceFlags.sampled,
	),
	attributes: <String, Object>{'batch.id': 'import-42'},
);

await Otel.instance.tracer.traceAsync(
	'process-item',
	links: <SpanLink>[link],
	fn: () async {
		Otel.instance.logger.info('linked work item');
	},
);
```

Span links are preserved on exported `SpanData` and included in OTLP JSON and protobuf span payloads.

## Testing

```dart
final helper = await OtelTestHelper.setup();

await Otel.instance.tracer.traceAsync('test-operation', fn: () async {
	Otel.instance.logger.info('inside test');
});

await Otel.forceFlush();

expect(helper.spanExporter.lastSpanNamed('test-operation'), isNotNull);
expect(helper.logExporter.logs.single.body, 'inside test');
```

`Otel.forceFlush()` now waits for in-flight simple span and log exports in addition to batch processors and metric readers.

Collector-backed integration coverage is also available:

```bash
dart test -t integration test/otlp_collector_integration_test.dart
```

That suite starts a real `otel/opentelemetry-collector-contrib` container through Docker, exports telemetry over OTLP HTTP/protobuf and OTLP gRPC, and verifies collector-observed traces, metrics, and logs from the files written by the collector.

It also includes wire-level integration coverage for:

- per-signal OTLP HTTP endpoints
- per-signal OTLP headers
- per-signal OTLP compression overrides
- per-signal OTLP timeout overrides
- OTLP HTTP/protobuf retry recovery when the collector becomes available late
- OTLP gRPC retry recovery when the collector becomes available late

Matcher helpers are also exported for test assertions:

```dart
expect(
	helper.spanExporter.spans,
	contains(allOf(hasSpanNamed('test-operation'), hasStatus(SpanStatus.ok))),
);

expect(
	helper.metricExporter.metrics,
	contains(allOf(
		hasMetricNamed('requests.total'),
		hasMetricType(MetricInstrumentType.counter),
	)),
);

final extracted = const CompositePropagator(<TextMapPropagator>[
	W3CTraceContextPropagator(),
	W3CBaggagePropagator(),
]).extract(<String, String>{
	'traceparent': '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01',
	'baggage': 'tenant.id=acme',
});

final expected = OtelContextSnapshot.remote(
	traceId: const TraceId('4bf92f3577b34da6a3ce929d0e0e4736'),
	spanId: const SpanId('00f067aa0ba902b7'),
	traceFlags: TraceFlags.sampled,
);

expect(extracted, hasRemoteSpanContext(sampled: true));
expect(extracted.traceIdValue, expected.traceIdValue);
expect(extracted, hasBaggageEntry('tenant.id', 'acme'));
```

## Semantic Attributes

The public `SemanticAttributes` surface now includes common keys for:

- service metadata
- HTTP
- database operations
- RPC
- network
- exception details
- Flutter-specific attributes

## Metrics Semantics

Current metrics behavior is now closer to OpenTelemetry expectations:

- counters and up-down counters are aggregated cumulatively by attribute set
- histograms emit aggregated count, sum, min, max, and bucket data
- metric points can carry start timestamps for cumulative temporality
- OTLP metric export uses temporality and monotonic flags from the metric model

## Integration Contracts

Core now exports stable building blocks for future integration packages:

- `OtelDatabaseMixin` for wrapping database operations in spans, metrics, and error logs
- `OtelDbMetrics` for reusable database metric instruments
- `SlowQueryDetector` for threshold-based slow query logging
- `OtelLogBridge` and `OtelLogExtension` for adapting external logging packages

## Composite Exporters

Core now includes composite exporters for fan-out delivery to multiple backends:

- `CompositeSpanExporter`
- `CompositeMetricExporter`
- `CompositeLogExporter`

They return `ExportResult.failure` if any child exporter fails.

## Isolate Support

Core now includes `OtelIsolate` and `OtelIsolateContext` for explicit context transfer across isolate boundaries.

- `OtelIsolate.captureCurrent()` snapshots the active span context and baggage into a sendable message shape
- `OtelIsolate.run(...)` restores baggage automatically inside the isolate callback
- if the isolate runtime initializes `Otel`, `spanName` can create a child span linked through `parentContext`

## OTLP HTTP JSON

```dart
await Otel.init(
	serviceName: 'my-app',
	endpoint: 'https://collector.example.com',
	tracesEndpoint: 'https://traces.example.com/v1/traces',
	metricsEndpoint: 'https://metrics.example.com/v1/metrics',
	logsEndpoint: 'https://logs.example.com/v1/logs',
	exporter: OtelExporter.otlpHttpJson,
	otlpCompression: OtlpCompression.gzip,
	otlpHeaders: <String, String>{
		'authorization': 'Bearer <token>',
	},
	otlpTracesHeaders: <String, String>{
		'x-trace-tenant': 'payments',
	},
	otlpTimeout: const Duration(seconds: 10),
	otlpTracesTimeout: const Duration(seconds: 3),
	otlpMetricsCompression: OtlpCompression.none,
	otlpRetry: const OtlpRetryConfig(
		maxAttempts: 3,
		initialDelay: Duration(milliseconds: 200),
	),
	otlpTracesRetry: const OtlpRetryConfig(
		maxAttempts: 5,
		initialDelay: Duration(milliseconds: 100),
	),
);
```

This uses `POST` requests to:

- `/v1/traces`
- `/v1/metrics`
- `/v1/logs`

Current OTLP JSON encoding also includes:

- numeric span kind and status codes
- `sum` payloads for counters and up-down counters
- `histogram` payloads with count, sum, min, max, explicit bounds, and bucket counts
- grouped resources and scopes for traces, metrics, and logs
- default `user-agent` header emission for OTLP requests
- optional gzip request compression via `otlpCompression` or `OTEL_EXPORTER_OTLP_COMPRESSION=gzip`
- retry/backoff for retryable HTTP responses and transient transport failures, including `Retry-After` on throttling responses (capped at `OtlpRetryConfig.maxDelay`)
- partial success handling for HTTP JSON and HTTP protobuf success responses without retrying accepted payloads
- resource-level SchemaURL propagation via `resourceSchemaUrl` in `Otel.init(...)`
- per-signal header overrides via `otlpTracesHeaders`, `otlpMetricsHeaders`, and `otlpLogsHeaders`
- per-signal timeout overrides via `otlpTracesTimeout`, `otlpMetricsTimeout`, and `otlpLogsTimeout`
- per-signal compression overrides via `otlpTracesCompression`, `otlpMetricsCompression`, and `otlpLogsCompression`
- per-signal retry overrides via `otlpTracesRetry`, `otlpMetricsRetry`, and `otlpLogsRetry`

## OTLP HTTP Protobuf

```dart
await Otel.init(
	serviceName: 'my-app',
	endpoint: 'https://collector.example.com',
	exporter: OtelExporter.otlpHttp,
	otlpHeaders: <String, String>{
		'authorization': 'Bearer <token>',
	},
	otlpCompression: OtlpCompression.gzip,
	otlpTimeout: const Duration(seconds: 10),
);
```

This uses OTLP over HTTP with `application/x-protobuf` request bodies and the same per-signal endpoint, header, timeout, compression, and retry configuration surface used by the JSON exporter.

## OTLP gRPC

```dart
await Otel.init(
	serviceName: 'my-app',
	endpoint: 'http://localhost:4317',
	exporter: OtelExporter.otlpGrpc,
	otlpHeaders: <String, String>{
		'x-tenant': 'payments',
	},
	otlpCompression: OtlpCompression.gzip,
	otlpTimeout: const Duration(seconds: 5),
);
```

The default gRPC transport routes signals to the standard collector services:

- `/opentelemetry.proto.collector.trace.v1.TraceService/Export`
- `/opentelemetry.proto.collector.metrics.v1.MetricsService/Export`
- `/opentelemetry.proto.collector.logs.v1.LogsService/Export`

It supports shared and per-signal headers, timeouts, compression, retry configuration, and resource-level SchemaURL propagation, and can be replaced in tests with an injected `otlpGrpcTransport`.
It also handles OTLP gRPC partial success responses without retrying the accepted payload.

## Environment Variables

Supported environment-driven config currently includes:

- `OTEL_SDK_DISABLED`
- `OTEL_PROPAGATORS`
- `OTEL_EXPORTER_OTLP_ENDPOINT`
- `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`
- `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`
- `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/json`
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`
- `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`
- `OTEL_EXPORTER_OTLP_TIMEOUT`
- `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT`
- `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT`
- `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT`
- `OTEL_EXPORTER_OTLP_COMPRESSION=gzip`
- `OTEL_EXPORTER_OTLP_TRACES_COMPRESSION`
- `OTEL_EXPORTER_OTLP_METRICS_COMPRESSION`
- `OTEL_EXPORTER_OTLP_LOGS_COMPRESSION`
- `OTEL_EXPORTER_OTLP_HEADERS`
- `OTEL_EXPORTER_OTLP_TRACES_HEADERS`
- `OTEL_EXPORTER_OTLP_METRICS_HEADERS`
- `OTEL_EXPORTER_OTLP_LOGS_HEADERS`
- `OTEL_RESOURCE_ATTRIBUTES`
- `OTEL_BSP_SCHEDULE_DELAY`
- `OTEL_BSP_EXPORT_TIMEOUT`
- `OTEL_BSP_MAX_QUEUE_SIZE`
- `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`
- `OTEL_BLRP_SCHEDULE_DELAY`
- `OTEL_BLRP_EXPORT_TIMEOUT`
- `OTEL_BLRP_MAX_QUEUE_SIZE`
- `OTEL_BLRP_MAX_EXPORT_BATCH_SIZE`
- `OTEL_METRIC_EXPORT_INTERVAL`
- `OTEL_METRIC_EXPORT_TIMEOUT`
- `OTEL_TRACES_SAMPLER`
- `OTEL_TRACES_SAMPLER_ARG`
- `OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT`
- `OTEL_SPAN_EVENT_COUNT_LIMIT`
- `OTEL_SPAN_LINK_COUNT_LIMIT`
- `OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT`
- `OTEL_LINK_ATTRIBUTE_COUNT_LIMIT`

Programmatic values override environment values where both are provided.
Signal-specific headers override shared OTLP headers for the matching signal only.
Signal-specific timeouts override the shared OTLP timeout for the matching signal only.
Signal-specific compression overrides the shared OTLP compression for the matching signal only.
Explicit `SpanLimits` passed into `Otel.init(...)` override env-derived span limit values for the fields you set directly.

## Advanced

- [spec-compliance-matrix.md](spec-compliance-matrix.md) for feature-by-feature notes on implementation status
- [CHANGELOG.md](CHANGELOG.md) for release history
- `README.md` sections below for OTLP HTTP JSON, OTLP HTTP Protobuf, gRPC, and environment configuration details

## Ecosystem

- [../comon_otel_flutter/README.md](../comon_otel_flutter/README.md): Flutter lifecycle, navigation, performance, interaction, and error instrumentation
- [../comon_otel_dio/README.md](../comon_otel_dio/README.md): Dio client spans and outgoing HTTP propagation

## Status

Implementation now includes tracing, metrics, logging, batch processors, periodic readers, baggage, and propagation foundations.
OTLP exporters and environment-driven config are now in place across HTTP JSON, HTTP protobuf, and gRPC transports.
