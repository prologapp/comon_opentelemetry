import '../context/propagation/global_propagator.dart';
import '../context/propagation/text_map_propagator.dart';
import '../exporters/log_exporter.dart';
import '../exporters/metric_exporter.dart';
import '../exporters/span_exporter.dart';
import '../exporters/console/console_log_exporter.dart';
import '../exporters/console/console_metric_exporter.dart';
import '../exporters/console/console_span_exporter.dart';
import '../exporters/otlp/common/export_retry.dart';
import '../exporters/otlp/grpc/grpc_log_exporter.dart';
import '../exporters/otlp/grpc/grpc_metric_exporter.dart';
import '../exporters/otlp/grpc/grpc_span_exporter.dart';
import '../exporters/otlp/json/http_json_log_exporter.dart';
import '../exporters/otlp/json/http_json_metric_exporter.dart';
import '../exporters/otlp/json/http_json_span_exporter.dart';
import '../exporters/otlp/protobuf/http_protobuf_log_exporter.dart';
import '../exporters/otlp/protobuf/http_protobuf_metric_exporter.dart';
import '../exporters/otlp/protobuf/http_protobuf_span_exporter.dart';
import '../exporters/otlp/grpc/grpc_transport.dart';
import '../exporters/otlp/common/http_transport.dart';
import '../logs/log_limits.dart';
import '../logs/log_processor.dart';
import '../logs/logger_provider.dart';
import '../logs/otel_logger.dart';
import '../logs/batch_log_processor.dart';
import '../logs/simple_log_processor.dart';
import '../metrics/meter.dart';
import '../metrics/meter_provider.dart';
import '../metrics/metric_reader.dart';
import '../metrics/periodic_metric_reader.dart';
import '../trace/batch_span_processor.dart';
import '../trace/sampler.dart';
import '../trace/session_span_processor.dart';
import '../trace/simple_span_processor.dart';
import '../trace/span_limits.dart';
import '../trace/span_processor.dart';
import '../trace/tracer.dart';
import '../trace/tracer_provider.dart';
import 'otel_config.dart';
import 'otel_env_config.dart';
import 'otel_exporter.dart';
import 'otel_session.dart';
import 'resource.dart';
import 'semantic_attributes.dart';

/// Global entry point for configuring and accessing the OpenTelemetry SDK.
///
/// Call [init] during application startup, then use [instance] or the static
/// convenience getters to access the shared providers.
final class Otel {
  Otel._({
    required this.config,
    required this.tracerProvider,
    required this.meterProvider,
    required this.loggerProvider,
  });

  static Otel? _instance;

  final OtelConfig config;
  final TracerProvider tracerProvider;
  final MeterProvider meterProvider;
  final LoggerProvider loggerProvider;

  /// Returns the active SDK instance.
  ///
  /// Throws a [StateError] if [init] has not been called yet.
  static Otel get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'Otel.init() must be called before Otel.instance is used.',
      );
    }
    return instance;
  }

  /// Whether the shared SDK instance has already been initialized.
  static bool get isInitialized => _instance != null;

  /// Creates or replaces the shared SDK instance.
  ///
  /// Explicit arguments override supported environment-based defaults.
  static Future<void> init({
    String serviceName = '',
    String? serviceVersion,
    List<ResourceDetector>? resourceDetectors,
    String? resourceSchemaUrl,
    String? endpoint,
    String? tracesEndpoint,
    String? metricsEndpoint,
    String? logsEndpoint,
    String? environment,
    OtelExporter exporter = OtelExporter.console,
    bool? sdkDisabled,
    int metricCardinalityLimit = 2000,
    TextMapPropagator? propagator,
    SamplerConfig? sampler,
    Map<String, Object>? resourceAttributes,
    SpanLimits spanLimits = const SpanLimits(),
    LogLimits logLimits = const LogLimits(),
    bool? useBatchSpanProcessor,
    Duration? batchSpanProcessorScheduleDelay,
    Duration? batchSpanProcessorExportTimeout,
    int? batchSpanProcessorMaxQueueSize,
    int? batchSpanProcessorMaxExportBatchSize,
    bool? useBatchLogProcessor,
    Duration? batchLogProcessorScheduleDelay,
    Duration? batchLogProcessorExportTimeout,
    int? batchLogProcessorMaxQueueSize,
    int? batchLogProcessorMaxExportBatchSize,
    bool? usePeriodicMetricReader,
    Duration? metricExportInterval,
    Duration? metricExportTimeout,
    List<SpanProcessor>? spanProcessors,
    List<LogProcessor>? logProcessors,
    List<MetricReader>? metricReaders,
    Map<String, String>? otlpHeaders,
    Map<String, String>? otlpTracesHeaders,
    Map<String, String>? otlpMetricsHeaders,
    Map<String, String>? otlpLogsHeaders,
    Duration otlpTimeout = const Duration(seconds: 10),
    Duration? otlpTracesTimeout,
    Duration? otlpMetricsTimeout,
    Duration? otlpLogsTimeout,
    OtlpCompression? otlpTracesCompression,
    OtlpCompression? otlpMetricsCompression,
    OtlpCompression? otlpLogsCompression,
    OtlpHttpTransport? otlpTransport,
    OtlpGrpcTransport? otlpGrpcTransport,
    OtlpCompression otlpCompression = OtlpCompression.none,
    OtlpRetryConfig otlpRetry = const OtlpRetryConfig(),
    OtlpRetryConfig? otlpTracesRetry,
    OtlpRetryConfig? otlpMetricsRetry,
    OtlpRetryConfig? otlpLogsRetry,
    String? previousSessionId,
  }) async {
    final existing = _instance;
    if (existing != null) {
      await existing.dispose();
    }

    final resolvedServiceName = serviceName.isEmpty
        ? (OtelEnvConfig.serviceName ?? Resource.defaultServiceName)
        : serviceName;
    final resolvedSdkDisabled = sdkDisabled ?? OtelEnvConfig.sdkDisabled;
    final resolvedEndpoint = endpoint ?? OtelEnvConfig.endpoint;
    final resolvedTracesEndpoint =
        tracesEndpoint ?? OtelEnvConfig.tracesEndpoint;
    final resolvedMetricsEndpoint =
        metricsEndpoint ?? OtelEnvConfig.metricsEndpoint;
    final resolvedLogsEndpoint = logsEndpoint ?? OtelEnvConfig.logsEndpoint;
    final resolvedExporter = exporter == OtelExporter.console
        ? (OtelEnvConfig.exporter ?? exporter)
        : exporter;
    final resolvedPropagator =
        propagator ??
        OtelEnvConfig.propagator ??
        GlobalPropagators.defaultPropagator;
    final resolvedSampler = sampler ?? OtelEnvConfig.sampler;
    final resolvedHeaders = <String, String>{
      ...OtelEnvConfig.headers,
      ...?otlpHeaders,
    };
    final resolvedTracesHeaders = <String, String>{
      ...resolvedHeaders,
      ...OtelEnvConfig.tracesHeaders,
      ...?otlpTracesHeaders,
    };
    final resolvedMetricsHeaders = <String, String>{
      ...resolvedHeaders,
      ...OtelEnvConfig.metricsHeaders,
      ...?otlpMetricsHeaders,
    };
    final resolvedLogsHeaders = <String, String>{
      ...resolvedHeaders,
      ...OtelEnvConfig.logsHeaders,
      ...?otlpLogsHeaders,
    };
    final resolvedTimeout = otlpTimeout == const Duration(seconds: 10)
        ? (OtelEnvConfig.timeout ?? otlpTimeout)
        : otlpTimeout;
    final resolvedTracesTimeout =
        otlpTracesTimeout ?? OtelEnvConfig.tracesTimeout ?? resolvedTimeout;
    final resolvedMetricsTimeout =
        otlpMetricsTimeout ?? OtelEnvConfig.metricsTimeout ?? resolvedTimeout;
    final resolvedLogsTimeout =
        otlpLogsTimeout ?? OtelEnvConfig.logsTimeout ?? resolvedTimeout;
    final resolvedCompression = otlpCompression == OtlpCompression.none
        ? (OtelEnvConfig.compression ?? otlpCompression)
        : otlpCompression;
    final resolvedTracesCompression =
        otlpTracesCompression ??
        OtelEnvConfig.tracesCompression ??
        resolvedCompression;
    final resolvedMetricsCompression =
        otlpMetricsCompression ??
        OtelEnvConfig.metricsCompression ??
        resolvedCompression;
    final resolvedLogsCompression =
        otlpLogsCompression ??
        OtelEnvConfig.logsCompression ??
        resolvedCompression;
    final resolvedTracesRetry = otlpTracesRetry ?? otlpRetry;
    final resolvedMetricsRetry = otlpMetricsRetry ?? otlpRetry;
    final resolvedLogsRetry = otlpLogsRetry ?? otlpRetry;
    final resolvedSpanLimits = _resolveSpanLimits(spanLimits);
    final resolvedResourceAttributes = <String, Object>{
      ...OtelEnvConfig.resourceAttributes,
      ...?resourceAttributes,
    };

    final config = OtelConfig(
      serviceName: resolvedServiceName,
      resourceSchemaUrl: resourceSchemaUrl,
      sdkDisabled: resolvedSdkDisabled,
      metricCardinalityLimit: metricCardinalityLimit,
      endpoint: resolvedEndpoint,
      tracesEndpoint: resolvedTracesEndpoint,
      metricsEndpoint: resolvedMetricsEndpoint,
      logsEndpoint: resolvedLogsEndpoint,
      environment: environment,
      exporter: resolvedExporter,
      propagator: resolvedPropagator,
      sampler: resolvedSampler,
      resourceAttributes: resolvedResourceAttributes,
      spanLimits: resolvedSpanLimits,
      logLimits: logLimits,
      useBatchSpanProcessor:
          useBatchSpanProcessor ?? OtelEnvConfig.hasBspConfig,
      batchSpanProcessorScheduleDelay:
          batchSpanProcessorScheduleDelay ?? OtelEnvConfig.bspScheduleDelay,
      batchSpanProcessorExportTimeout:
          batchSpanProcessorExportTimeout ?? OtelEnvConfig.bspExportTimeout,
      batchSpanProcessorMaxQueueSize:
          batchSpanProcessorMaxQueueSize ?? OtelEnvConfig.bspMaxQueueSize,
      batchSpanProcessorMaxExportBatchSize:
          batchSpanProcessorMaxExportBatchSize ??
          OtelEnvConfig.bspMaxExportBatchSize,
      useBatchLogProcessor: useBatchLogProcessor ?? OtelEnvConfig.hasBlrpConfig,
      batchLogProcessorScheduleDelay:
          batchLogProcessorScheduleDelay ?? OtelEnvConfig.blrpScheduleDelay,
      batchLogProcessorExportTimeout:
          batchLogProcessorExportTimeout ?? OtelEnvConfig.blrpExportTimeout,
      batchLogProcessorMaxQueueSize:
          batchLogProcessorMaxQueueSize ?? OtelEnvConfig.blrpMaxQueueSize,
      batchLogProcessorMaxExportBatchSize:
          batchLogProcessorMaxExportBatchSize ??
          OtelEnvConfig.blrpMaxExportBatchSize,
      usePeriodicMetricReader:
          usePeriodicMetricReader ?? OtelEnvConfig.hasMetricReaderConfig,
      metricExportInterval:
          metricExportInterval ?? OtelEnvConfig.metricExportInterval,
      metricExportTimeout:
          metricExportTimeout ?? OtelEnvConfig.metricExportTimeout,
      spanProcessors: spanProcessors ?? const <SpanProcessor>[],
      logProcessors: logProcessors ?? const <LogProcessor>[],
      metricReaders: metricReaders ?? const <MetricReader>[],
      otlpHeaders: resolvedHeaders,
      otlpTracesHeaders: resolvedTracesHeaders,
      otlpMetricsHeaders: resolvedMetricsHeaders,
      otlpLogsHeaders: resolvedLogsHeaders,
      otlpTimeout: resolvedTimeout,
      otlpTracesTimeout: resolvedTracesTimeout,
      otlpMetricsTimeout: resolvedMetricsTimeout,
      otlpLogsTimeout: resolvedLogsTimeout,
      otlpTracesCompression: resolvedTracesCompression,
      otlpMetricsCompression: resolvedMetricsCompression,
      otlpLogsCompression: resolvedLogsCompression,
      otlpTransport: otlpTransport,
      otlpGrpcTransport: otlpGrpcTransport,
      otlpCompression: resolvedCompression,
      otlpRetry: otlpRetry,
      otlpTracesRetry: resolvedTracesRetry,
      otlpMetricsRetry: resolvedMetricsRetry,
      otlpLogsRetry: resolvedLogsRetry,
    );

    final resource = Resource.autoDetect(
      serviceName: resolvedServiceName,
      serviceVersion: serviceVersion,
      environment: environment,
      schemaUrl: resourceSchemaUrl,
      detectors: resourceDetectors,
      extra: resolvedResourceAttributes,
    );

    GlobalPropagators.set(resolvedPropagator);

    final processors = resolvedSdkDisabled
        ? const <SpanProcessor>[]
        : <SpanProcessor>[
            SessionSpanProcessor(),
            ..._buildSpanProcessors(config),
          ];
    final tracerProvider = TracerProvider(
      resource: resource,
      spanProcessors: processors,
      sampler: resolvedSdkDisabled
          ? const AlwaysOffSampler()
          : (resolvedSampler?.build() ?? const AlwaysOnSampler()),
      spanLimits: config.spanLimits,
    );

    final meterProvider = MeterProvider(
      resource: resource,
      metricCardinalityLimit: config.metricCardinalityLimit,
      readers: resolvedSdkDisabled
          ? const <MetricReader>[]
          : _buildMetricReaders(config),
    );

    final loggerProvider = LoggerProvider(
      resource: resource,
      logLimits: config.logLimits,
      logProcessors: resolvedSdkDisabled
          ? const <LogProcessor>[]
          : _buildLogProcessors(config),
    );

    _instance = Otel._(
      config: config,
      tracerProvider: tracerProvider,
      meterProvider: meterProvider,
      loggerProvider: loggerProvider,
    );

    if (!resolvedSdkDisabled &&
        previousSessionId != null &&
        previousSessionId.isNotEmpty &&
        previousSessionId != OtelSession.id &&
        OtelSession.claimRotationEmission()) {
      final span = tracerProvider
          .getTracer('comon_otel')
          .startSpan(
            'session.rotation',
            attributes: <String, Object>{
              SemanticAttributes.sessionId: OtelSession.id,
              SemanticAttributes.sessionPreviousId: previousSessionId,
            },
          );
      await span.end();
    }
  }

  /// The current isolate's session id. See [OtelSession] for the identity
  /// contract (lazy per-isolate id, unaffected by re-`init`).
  static String get sessionId => OtelSession.id;

  static List<SpanProcessor> _buildSpanProcessors(OtelConfig config) {
    if (config.spanProcessors.isNotEmpty) {
      return config.spanProcessors;
    }

    final exporter = _buildSpanExporter(config);
    if (config.useBatchSpanProcessor) {
      return <SpanProcessor>[
        BatchSpanProcessor(
          exporter: exporter,
          maxBatchSize: config.batchSpanProcessorMaxExportBatchSize ?? 512,
          scheduleDelay:
              config.batchSpanProcessorScheduleDelay ??
              const Duration(seconds: 5),
          maxQueueSize: config.batchSpanProcessorMaxQueueSize ?? 2048,
          exportTimeout: config.batchSpanProcessorExportTimeout,
        ),
      ];
    }

    return <SpanProcessor>[SimpleSpanProcessor(exporter)];
  }

  static List<MetricReader> _buildMetricReaders(OtelConfig config) {
    if (config.metricReaders.isNotEmpty) {
      return config.metricReaders;
    }

    final exporter = _buildMetricExporter(config);
    if (config.usePeriodicMetricReader) {
      return <MetricReader>[
        PeriodicMetricReader(
          exporter: exporter,
          interval: config.metricExportInterval ?? const Duration(seconds: 60),
          exportTimeout: config.metricExportTimeout,
        ),
      ];
    }

    return <MetricReader>[ExportingMetricReader(exporter: exporter)];
  }

  static List<LogProcessor> _buildLogProcessors(OtelConfig config) {
    if (config.logProcessors.isNotEmpty) {
      return config.logProcessors;
    }

    final exporter = _buildLogExporter(config);
    if (config.useBatchLogProcessor) {
      return <LogProcessor>[
        BatchLogProcessor(
          exporter: exporter,
          maxBatchSize: config.batchLogProcessorMaxExportBatchSize ?? 512,
          scheduleDelay:
              config.batchLogProcessorScheduleDelay ??
              const Duration(seconds: 1),
          maxQueueSize: config.batchLogProcessorMaxQueueSize ?? 2048,
          exportTimeout: config.batchLogProcessorExportTimeout,
        ),
      ];
    }

    return <LogProcessor>[SimpleLogProcessor(exporter)];
  }

  static SpanExporter _buildSpanExporter(OtelConfig config) {
    switch (config.exporter) {
      case OtelExporter.console:
        return ConsoleSpanExporter();
      case OtelExporter.otlpHttp:
        return OtlpHttpProtobufSpanExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.tracesEndpoint,
          ),
          appendSignalPath: config.tracesEndpoint == null,
          headers: config.otlpTracesHeaders,
          timeout: config.otlpTracesTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpTracesCompression,
          retry: config.otlpTracesRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpHttpJson:
        return OtlpHttpJsonSpanExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.tracesEndpoint,
          ),
          appendSignalPath: config.tracesEndpoint == null,
          headers: config.otlpTracesHeaders,
          timeout: config.otlpTracesTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpTracesCompression,
          retry: config.otlpTracesRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpGrpc:
        return OtlpGrpcSpanExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.tracesEndpoint,
          ),
          headers: config.otlpTracesHeaders,
          timeout: config.otlpTracesTimeout ?? config.otlpTimeout,
          transport: config.otlpGrpcTransport,
          compression: config.otlpTracesCompression,
          retry: config.otlpTracesRetry ?? config.otlpRetry,
        );
    }
  }

  static MetricExporter _buildMetricExporter(OtelConfig config) {
    switch (config.exporter) {
      case OtelExporter.console:
        return ConsoleMetricExporter();
      case OtelExporter.otlpHttp:
        return OtlpHttpProtobufMetricExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.metricsEndpoint,
          ),
          appendSignalPath: config.metricsEndpoint == null,
          headers: config.otlpMetricsHeaders,
          timeout: config.otlpMetricsTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpMetricsCompression,
          retry: config.otlpMetricsRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpHttpJson:
        return OtlpHttpJsonMetricExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.metricsEndpoint,
          ),
          appendSignalPath: config.metricsEndpoint == null,
          headers: config.otlpMetricsHeaders,
          timeout: config.otlpMetricsTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpMetricsCompression,
          retry: config.otlpMetricsRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpGrpc:
        return OtlpGrpcMetricExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.metricsEndpoint,
          ),
          headers: config.otlpMetricsHeaders,
          timeout: config.otlpMetricsTimeout ?? config.otlpTimeout,
          transport: config.otlpGrpcTransport,
          compression: config.otlpMetricsCompression,
          retry: config.otlpMetricsRetry ?? config.otlpRetry,
        );
    }
  }

  static LogExporter _buildLogExporter(OtelConfig config) {
    switch (config.exporter) {
      case OtelExporter.console:
        return ConsoleLogExporter();
      case OtelExporter.otlpHttp:
        return OtlpHttpProtobufLogExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.logsEndpoint,
          ),
          appendSignalPath: config.logsEndpoint == null,
          headers: config.otlpLogsHeaders,
          timeout: config.otlpLogsTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpLogsCompression,
          retry: config.otlpLogsRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpHttpJson:
        return OtlpHttpJsonLogExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.logsEndpoint,
          ),
          appendSignalPath: config.logsEndpoint == null,
          headers: config.otlpLogsHeaders,
          timeout: config.otlpLogsTimeout ?? config.otlpTimeout,
          transport: config.otlpTransport,
          compression: config.otlpLogsCompression,
          retry: config.otlpLogsRetry ?? config.otlpRetry,
        );
      case OtelExporter.otlpGrpc:
        return OtlpGrpcLogExporter(
          endpoint: _requireSignalEndpoint(
            config: config,
            signalEndpoint: config.logsEndpoint,
          ),
          headers: config.otlpLogsHeaders,
          timeout: config.otlpLogsTimeout ?? config.otlpTimeout,
          transport: config.otlpGrpcTransport,
          compression: config.otlpLogsCompression,
          retry: config.otlpLogsRetry ?? config.otlpRetry,
        );
    }
  }

  static SpanLimits _resolveSpanLimits(SpanLimits spanLimits) {
    const defaultLimits = SpanLimits();
    return SpanLimits(
      attributeCountLimit:
          spanLimits.attributeCountLimit == defaultLimits.attributeCountLimit
          ? (OtelEnvConfig.spanAttributeCountLimit ??
                spanLimits.attributeCountLimit)
          : spanLimits.attributeCountLimit,
      eventCountLimit:
          spanLimits.eventCountLimit == defaultLimits.eventCountLimit
          ? (OtelEnvConfig.spanEventCountLimit ?? spanLimits.eventCountLimit)
          : spanLimits.eventCountLimit,
      linkCountLimit: spanLimits.linkCountLimit == defaultLimits.linkCountLimit
          ? (OtelEnvConfig.spanLinkCountLimit ?? spanLimits.linkCountLimit)
          : spanLimits.linkCountLimit,
      attributePerEventCountLimit:
          spanLimits.attributePerEventCountLimit ==
              defaultLimits.attributePerEventCountLimit
          ? (OtelEnvConfig.eventAttributeCountLimit ??
                spanLimits.attributePerEventCountLimit)
          : spanLimits.attributePerEventCountLimit,
      attributePerLinkCountLimit:
          spanLimits.attributePerLinkCountLimit ==
              defaultLimits.attributePerLinkCountLimit
          ? (OtelEnvConfig.linkAttributeCountLimit ??
                spanLimits.attributePerLinkCountLimit)
          : spanLimits.attributePerLinkCountLimit,
      attributeValueLengthLimit: spanLimits.attributeValueLengthLimit,
    );
  }

  static String _requireEndpoint(OtelConfig config) {
    final endpoint = config.endpoint;
    if (endpoint == null || endpoint.isEmpty) {
      throw ArgumentError(
        'endpoint is required when exporter is set to ${config.exporter.name}.',
      );
    }
    return endpoint;
  }

  static String _requireSignalEndpoint({
    required OtelConfig config,
    required String? signalEndpoint,
  }) {
    if (signalEndpoint != null && signalEndpoint.isNotEmpty) {
      return signalEndpoint;
    }
    return _requireEndpoint(config);
  }

  static TextMapPropagator get propagator => GlobalPropagators.instance;

  /// Replaces the global propagator used by the SDK.
  static void setPropagator(TextMapPropagator propagator) {
    GlobalPropagators.set(propagator);
  }

  /// Restores the default global propagator.
  static void resetPropagator() {
    GlobalPropagators.reset();
  }

  /// Returns a default tracer scoped to `comon_otel`.
  Tracer get tracer => tracerProvider.getTracer('comon_otel');

  /// Returns a default meter scoped to `comon_otel`.
  Meter get meter => meterProvider.getMeter('comon_otel');

  /// Returns a default logger scoped to `comon_otel`.
  OtelLogger get logger => loggerProvider.getLogger('comon_otel');

  /// Shuts down the current providers and clears the singleton if needed.
  ///
  /// Each signal is shut down independently: a failure in one never skips
  /// the others, and no error is propagated to the caller.
  Future<void> dispose() async {
    for (final shutdown in <Future<void> Function()>[
      tracerProvider.shutdown,
      meterProvider.shutdown,
      loggerProvider.shutdown,
    ]) {
      try {
        await shutdown();
      } catch (_) {
        // Telemetry never throws into the host.
      }
    }
    if (identical(_instance, this)) {
      _instance = null;
    }
  }

  /// Flushes pending trace, metric, and log exports.
  ///
  /// Each signal is flushed independently: a failure in one (e.g. a metric
  /// exporter that throws) never prevents the others from flushing, and no
  /// error is propagated to the caller.
  static Future<void> forceFlush() async {
    final otel = instance;
    for (final flush in <Future<void> Function()>[
      otel.tracerProvider.forceFlush,
      otel.meterProvider.forceFlush,
      otel.loggerProvider.forceFlush,
    ]) {
      try {
        await flush();
      } catch (_) {
        // Telemetry never throws into the host.
      }
    }
  }

  /// Shuts down the shared SDK instance, if it exists.
  static Future<void> shutdown() async {
    final existing = _instance;
    if (existing == null) {
      return;
    }
    await existing.dispose();
  }
}
