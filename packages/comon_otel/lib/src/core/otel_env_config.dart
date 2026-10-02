import '../context/propagation/global_propagator.dart';
import '../context/propagation/text_map_propagator.dart';
import '../exporters/otlp/common/http_transport.dart';
import '../trace/sampler.dart';
import '../trace/span_limits.dart';
import 'otel_exporter.dart';
import 'platform_runtime.dart';

/// Environment variable source used by [OtelEnvConfig].
typedef EnvSource = Map<String, String> Function();

/// Reads SDK configuration defaults from OpenTelemetry environment variables.
final class OtelEnvConfig {
  const OtelEnvConfig._();

  static EnvSource _envSource = _defaultEnvSource;

  static Map<String, String> _defaultEnvSource() => platformEnvironment();

  /// Current environment map.
  static Map<String, String> get env => _envSource();

  /// Overrides the environment source, primarily for tests.
  static void overrideEnvSource(EnvSource source) {
    _envSource = source;
  }

  /// Restores the default platform environment source.
  static void resetEnvSource() {
    _envSource = _defaultEnvSource;
  }

  /// Shared OTLP endpoint.
  static String? get endpoint => env['OTEL_EXPORTER_OTLP_ENDPOINT'];

  /// Trace-specific OTLP endpoint.
  static String? get tracesEndpoint =>
      env['OTEL_EXPORTER_OTLP_TRACES_ENDPOINT'];

  /// Metric-specific OTLP endpoint.
  static String? get metricsEndpoint =>
      env['OTEL_EXPORTER_OTLP_METRICS_ENDPOINT'];

  /// Log-specific OTLP endpoint.
  static String? get logsEndpoint => env['OTEL_EXPORTER_OTLP_LOGS_ENDPOINT'];

  /// Service name override.
  static String? get serviceName => env['OTEL_SERVICE_NAME'];

  /// Whether the SDK is disabled.
  static bool get sdkDisabled =>
      _parseBoolean(env['OTEL_SDK_DISABLED']) ?? false;

  /// OTLP protocol string.
  static String? get protocol => env['OTEL_EXPORTER_OTLP_PROTOCOL'];

  /// Parsed propagator configuration.
  static TextMapPropagator? get propagator =>
      GlobalPropagators.parse(env['OTEL_PROPAGATORS']);

  /// Shared OTLP headers.
  static Map<String, String> get headers =>
      _parseCommaSeparatedKeyValue(env['OTEL_EXPORTER_OTLP_HEADERS']);

  /// Trace-specific OTLP headers.
  static Map<String, String> get tracesHeaders =>
      _parseCommaSeparatedKeyValue(env['OTEL_EXPORTER_OTLP_TRACES_HEADERS']);

  /// Metric-specific OTLP headers.
  static Map<String, String> get metricsHeaders =>
      _parseCommaSeparatedKeyValue(env['OTEL_EXPORTER_OTLP_METRICS_HEADERS']);

  /// Log-specific OTLP headers.
  static Map<String, String> get logsHeaders =>
      _parseCommaSeparatedKeyValue(env['OTEL_EXPORTER_OTLP_LOGS_HEADERS']);

  /// Shared OTLP timeout.
  static Duration? get timeout =>
      _parseDurationMillis(env['OTEL_EXPORTER_OTLP_TIMEOUT']);

  /// Trace-specific OTLP timeout.
  static Duration? get tracesTimeout =>
      _parseDurationMillis(env['OTEL_EXPORTER_OTLP_TRACES_TIMEOUT']);

  /// Metric-specific OTLP timeout.
  static Duration? get metricsTimeout =>
      _parseDurationMillis(env['OTEL_EXPORTER_OTLP_METRICS_TIMEOUT']);

  /// Log-specific OTLP timeout.
  static Duration? get logsTimeout =>
      _parseDurationMillis(env['OTEL_EXPORTER_OTLP_LOGS_TIMEOUT']);

  /// Trace-specific OTLP compression.
  static OtlpCompression? get tracesCompression =>
      _parseCompression(env['OTEL_EXPORTER_OTLP_TRACES_COMPRESSION']);

  /// Metric-specific OTLP compression.
  static OtlpCompression? get metricsCompression =>
      _parseCompression(env['OTEL_EXPORTER_OTLP_METRICS_COMPRESSION']);

  /// Log-specific OTLP compression.
  static OtlpCompression? get logsCompression =>
      _parseCompression(env['OTEL_EXPORTER_OTLP_LOGS_COMPRESSION']);

  /// Shared OTLP compression.
  static OtlpCompression? get compression {
    return _parseCompression(env['OTEL_EXPORTER_OTLP_COMPRESSION']);
  }

  /// Parsed resource attributes from `OTEL_RESOURCE_ATTRIBUTES`.
  static Map<String, String> get resourceAttributes =>
      _parseCommaSeparatedKeyValue(env['OTEL_RESOURCE_ATTRIBUTES']);

  /// Span attribute count limit override.
  static int? get spanAttributeCountLimit =>
      _parsePositiveInt(env['OTEL_SPAN_ATTRIBUTE_COUNT_LIMIT']);

  /// Span event count limit override.
  static int? get spanEventCountLimit =>
      _parsePositiveInt(env['OTEL_SPAN_EVENT_COUNT_LIMIT']);

  /// Span link count limit override.
  static int? get spanLinkCountLimit =>
      _parsePositiveInt(env['OTEL_SPAN_LINK_COUNT_LIMIT']);

  /// Event attribute count limit override.
  static int? get eventAttributeCountLimit =>
      _parsePositiveInt(env['OTEL_EVENT_ATTRIBUTE_COUNT_LIMIT']);

  /// Link attribute count limit override.
  static int? get linkAttributeCountLimit =>
      _parsePositiveInt(env['OTEL_LINK_ATTRIBUTE_COUNT_LIMIT']);

  /// Batch span processor schedule delay override.
  static Duration? get bspScheduleDelay =>
      _parseDurationMillis(env['OTEL_BSP_SCHEDULE_DELAY']);

  /// Batch span processor export timeout override.
  static Duration? get bspExportTimeout =>
      _parseDurationMillis(env['OTEL_BSP_EXPORT_TIMEOUT']);

  /// Batch span processor queue size override.
  static int? get bspMaxQueueSize =>
      _parsePositiveInt(env['OTEL_BSP_MAX_QUEUE_SIZE']);

  /// Batch span processor batch size override.
  static int? get bspMaxExportBatchSize =>
      _parsePositiveInt(env['OTEL_BSP_MAX_EXPORT_BATCH_SIZE']);

  /// Whether any batch span processor overrides are present.
  static bool get hasBspConfig =>
      bspScheduleDelay != null ||
      bspExportTimeout != null ||
      bspMaxQueueSize != null ||
      bspMaxExportBatchSize != null;

  /// Batch log processor schedule delay override.
  static Duration? get blrpScheduleDelay =>
      _parseDurationMillis(env['OTEL_BLRP_SCHEDULE_DELAY']);

  /// Batch log processor export timeout override.
  static Duration? get blrpExportTimeout =>
      _parseDurationMillis(env['OTEL_BLRP_EXPORT_TIMEOUT']);

  /// Batch log processor queue size override.
  static int? get blrpMaxQueueSize =>
      _parsePositiveInt(env['OTEL_BLRP_MAX_QUEUE_SIZE']);

  /// Batch log processor batch size override.
  static int? get blrpMaxExportBatchSize =>
      _parsePositiveInt(env['OTEL_BLRP_MAX_EXPORT_BATCH_SIZE']);

  /// Whether any batch log processor overrides are present.
  static bool get hasBlrpConfig =>
      blrpScheduleDelay != null ||
      blrpExportTimeout != null ||
      blrpMaxQueueSize != null ||
      blrpMaxExportBatchSize != null;

  /// Metric export interval override.
  static Duration? get metricExportInterval =>
      _parseDurationMillis(env['OTEL_METRIC_EXPORT_INTERVAL']);

  /// Metric export timeout override.
  static Duration? get metricExportTimeout =>
      _parseDurationMillis(env['OTEL_METRIC_EXPORT_TIMEOUT']);

  /// Whether any metric reader overrides are present.
  static bool get hasMetricReaderConfig =>
      metricExportInterval != null || metricExportTimeout != null;

  /// Resolves span limits using environment overrides when present.
  static SpanLimits resolveSpanLimits(SpanLimits fallback) {
    return SpanLimits(
      attributeCountLimit:
          spanAttributeCountLimit ?? fallback.attributeCountLimit,
      eventCountLimit: spanEventCountLimit ?? fallback.eventCountLimit,
      linkCountLimit: spanLinkCountLimit ?? fallback.linkCountLimit,
      attributePerEventCountLimit:
          eventAttributeCountLimit ?? fallback.attributePerEventCountLimit,
      attributePerLinkCountLimit:
          linkAttributeCountLimit ?? fallback.attributePerLinkCountLimit,
      attributeValueLengthLimit: fallback.attributeValueLengthLimit,
    );
  }

  /// Parsed sampler configuration from environment variables.
  static SamplerConfig? get sampler {
    final samplerName = env['OTEL_TRACES_SAMPLER'];
    if (samplerName == null || samplerName.isEmpty) {
      return null;
    }

    final samplerArg =
        double.tryParse(env['OTEL_TRACES_SAMPLER_ARG'] ?? '') ?? 1.0;

    switch (samplerName.toLowerCase()) {
      case 'always_on':
        return SamplerConfig.alwaysOn();
      case 'always_off':
        return SamplerConfig.alwaysOff();
      case 'traceidratio':
        return SamplerConfig.ratio(samplerArg);
      case 'parentbased_traceidratio':
        return SamplerConfig.parentBased(rootRatio: samplerArg);
      default:
        return null;
    }
  }

  /// Exporter preset derived from `OTEL_EXPORTER_OTLP_PROTOCOL`.
  static OtelExporter? get exporter {
    final value = protocol?.toLowerCase();
    switch (value) {
      case 'http/protobuf':
        return OtelExporter.otlpHttp;
      case 'http/json':
        return OtelExporter.otlpHttpJson;
      case 'grpc':
        return OtelExporter.otlpGrpc;
      case null:
      case '':
        return null;
      default:
        return null;
    }
  }

  static Map<String, String> _parseCommaSeparatedKeyValue(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return const <String, String>{};
    }

    final values = <String, String>{};
    for (final pair in raw.split(',')) {
      final index = pair.indexOf('=');
      if (index <= 0) {
        continue;
      }
      final key = pair.substring(0, index).trim();
      final value = pair.substring(index + 1).trim();
      if (key.isEmpty) {
        continue;
      }
      values[key] = value;
    }
    return values;
  }

  static Duration? _parseDurationMillis(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final milliseconds = int.tryParse(raw.trim());
    if (milliseconds == null || milliseconds < 0) {
      return null;
    }

    return Duration(milliseconds: milliseconds);
  }

  static bool? _parseBoolean(String? raw) {
    switch (raw?.trim().toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
      case null:
      case '':
        return null;
      default:
        return null;
    }
  }

  static int? _parsePositiveInt(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }

    final value = int.tryParse(raw.trim());
    if (value == null || value <= 0) {
      return null;
    }

    return value;
  }

  static OtlpCompression? _parseCompression(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'gzip':
        return OtlpCompression.gzip;
      case 'none':
        return OtlpCompression.none;
      case null:
      case '':
        return null;
      default:
        return null;
    }
  }
}
