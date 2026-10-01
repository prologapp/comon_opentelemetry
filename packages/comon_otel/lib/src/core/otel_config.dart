import '../context/propagation/global_propagator.dart';
import '../context/propagation/text_map_propagator.dart';
import '../exporters/otlp/common/export_retry.dart';
import '../exporters/otlp/grpc/grpc_transport.dart';
import '../exporters/otlp/common/http_transport.dart';
import '../logs/log_limits.dart';
import '../logs/log_processor.dart';
import '../metrics/metric_reader.dart';
import '../trace/sampler.dart';
import '../trace/span_limits.dart';
import '../trace/span_processor.dart';
import 'otel_exporter.dart';

/// Immutable SDK configuration resolved by [Otel.init].
///
/// This snapshot captures the effective runtime settings after combining
/// explicit arguments with environment-driven defaults.
final class OtelConfig {
  /// Creates an SDK configuration snapshot.
  const OtelConfig({
    required this.serviceName,
    this.sdkDisabled = false,
    this.metricCardinalityLimit = 2000,
    this.resourceSchemaUrl,
    this.endpoint,
    this.tracesEndpoint,
    this.metricsEndpoint,
    this.logsEndpoint,
    this.environment,
    this.exporter = OtelExporter.console,
    this.propagator = GlobalPropagators.defaultPropagator,
    this.sampler,
    this.resourceAttributes = const <String, Object>{},
    this.spanLimits = const SpanLimits(),
    this.logLimits = const LogLimits(),
    this.useBatchSpanProcessor = false,
    this.batchSpanProcessorScheduleDelay,
    this.batchSpanProcessorExportTimeout,
    this.batchSpanProcessorMaxQueueSize,
    this.batchSpanProcessorMaxExportBatchSize,
    this.useBatchLogProcessor = false,
    this.batchLogProcessorScheduleDelay,
    this.batchLogProcessorExportTimeout,
    this.batchLogProcessorMaxQueueSize,
    this.batchLogProcessorMaxExportBatchSize,
    this.usePeriodicMetricReader = false,
    this.metricExportInterval,
    this.metricExportTimeout,
    this.spanProcessors = const <SpanProcessor>[],
    this.logProcessors = const <LogProcessor>[],
    this.metricReaders = const <MetricReader>[],
    this.otlpHeaders = const <String, String>{},
    this.otlpTracesHeaders = const <String, String>{},
    this.otlpMetricsHeaders = const <String, String>{},
    this.otlpLogsHeaders = const <String, String>{},
    this.otlpTimeout = const Duration(seconds: 10),
    this.otlpTracesTimeout,
    this.otlpMetricsTimeout,
    this.otlpLogsTimeout,
    this.otlpTracesCompression = OtlpCompression.none,
    this.otlpMetricsCompression = OtlpCompression.none,
    this.otlpLogsCompression = OtlpCompression.none,
    this.otlpTransport,
    this.otlpGrpcTransport,
    this.otlpCompression = OtlpCompression.none,
    this.otlpRetry = const OtlpRetryConfig(),
    this.otlpTracesRetry,
    this.otlpMetricsRetry,
    this.otlpLogsRetry,
  });

  /// Logical service name reported on emitted resources.
  final String serviceName;

  /// Whether signal collection and export are disabled.
  final bool sdkDisabled;

  /// Maximum number of distinct metric attribute sets retained per instrument.
  final int metricCardinalityLimit;

  /// Optional schema URL attached to the emitted resource.
  final String? resourceSchemaUrl;

  /// Shared OTLP endpoint used when per-signal endpoints are not set.
  final String? endpoint;

  /// OTLP endpoint override for trace exports.
  final String? tracesEndpoint;

  /// OTLP endpoint override for metric exports.
  final String? metricsEndpoint;

  /// OTLP endpoint override for log exports.
  final String? logsEndpoint;

  /// Deployment environment such as `dev`, `staging`, or `prod`.
  final String? environment;

  /// Export pipeline preset used when explicit processors/readers are omitted.
  final OtelExporter exporter;

  /// Global text map propagator used for injection and extraction.
  final TextMapPropagator propagator;

  /// Optional sampler configuration for new spans.
  final SamplerConfig? sampler;

  /// Extra resource attributes merged with auto-detected values.
  final Map<String, Object> resourceAttributes;

  /// Limits applied to span attributes, events, and links.
  final SpanLimits spanLimits;

  /// Limits applied to log record attributes and bodies.
  final LogLimits logLimits;

  /// Whether to add the built-in batch span processor.
  final bool useBatchSpanProcessor;

  /// Schedule delay for the built-in batch span processor.
  final Duration? batchSpanProcessorScheduleDelay;

  /// Export timeout for the built-in batch span processor.
  final Duration? batchSpanProcessorExportTimeout;

  /// Maximum queue size for the built-in batch span processor.
  final int? batchSpanProcessorMaxQueueSize;

  /// Maximum export batch size for the built-in batch span processor.
  final int? batchSpanProcessorMaxExportBatchSize;

  /// Whether to add the built-in batch log processor.
  final bool useBatchLogProcessor;

  /// Schedule delay for the built-in batch log processor.
  final Duration? batchLogProcessorScheduleDelay;

  /// Export timeout for the built-in batch log processor.
  final Duration? batchLogProcessorExportTimeout;

  /// Maximum queue size for the built-in batch log processor.
  final int? batchLogProcessorMaxQueueSize;

  /// Maximum export batch size for the built-in batch log processor.
  final int? batchLogProcessorMaxExportBatchSize;

  /// Whether to add the built-in periodic metric reader.
  final bool usePeriodicMetricReader;

  /// Export interval for the built-in periodic metric reader.
  final Duration? metricExportInterval;

  /// Export timeout for the built-in periodic metric reader.
  final Duration? metricExportTimeout;

  /// Additional span processors appended to the built-in pipeline.
  final List<SpanProcessor> spanProcessors;

  /// Additional log processors appended to the built-in pipeline.
  final List<LogProcessor> logProcessors;

  /// Additional metric readers appended to the built-in pipeline.
  final List<MetricReader> metricReaders;

  /// Headers applied to every OTLP request unless overridden per signal.
  final Map<String, String> otlpHeaders;

  /// Additional headers applied only to trace OTLP requests.
  final Map<String, String> otlpTracesHeaders;

  /// Additional headers applied only to metric OTLP requests.
  final Map<String, String> otlpMetricsHeaders;

  /// Additional headers applied only to log OTLP requests.
  final Map<String, String> otlpLogsHeaders;

  /// Default OTLP timeout used when a per-signal timeout is absent.
  final Duration otlpTimeout;

  /// Trace-specific OTLP timeout override.
  final Duration? otlpTracesTimeout;

  /// Metric-specific OTLP timeout override.
  final Duration? otlpMetricsTimeout;

  /// Log-specific OTLP timeout override.
  final Duration? otlpLogsTimeout;

  /// Compression used for OTLP trace exports.
  final OtlpCompression otlpTracesCompression;

  /// Compression used for OTLP metric exports.
  final OtlpCompression otlpMetricsCompression;

  /// Compression used for OTLP log exports.
  final OtlpCompression otlpLogsCompression;

  /// Optional custom HTTP transport for OTLP HTTP exporters.
  final OtlpHttpTransport? otlpTransport;

  /// Optional custom gRPC transport for OTLP gRPC exporters.
  final OtlpGrpcTransport? otlpGrpcTransport;

  /// Shared OTLP compression fallback used when per-signal values are absent.
  final OtlpCompression otlpCompression;

  /// Default OTLP retry policy used when a per-signal policy is absent.
  final OtlpRetryConfig otlpRetry;

  /// Trace-specific OTLP retry override.
  final OtlpRetryConfig? otlpTracesRetry;

  /// Metric-specific OTLP retry override.
  final OtlpRetryConfig? otlpMetricsRetry;

  /// Log-specific OTLP retry override.
  final OtlpRetryConfig? otlpLogsRetry;
}
