import '../../../metrics/metric_data.dart';
import '../../metric_exporter.dart';
import '../../span_exporter.dart';
import '../common/exporter_headers.dart';
import '../common/export_response.dart';
import '../common/export_retry.dart';
import '../common/http_transport.dart';
import '../protobuf/protobuf_codec.dart';
import 'grpc_transport.dart';

/// OTLP gRPC exporter for metrics.
final class OtlpGrpcMetricExporter implements MetricExporter {
  /// Creates an OTLP gRPC metric exporter.
  OtlpGrpcMetricExporter({
    required String endpoint,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    OtlpGrpcTransport? transport,
    OtlpCompression compression = OtlpCompression.none,
    OtlpRetryConfig retry = const OtlpRetryConfig(),
  }) : _endpoint = endpoint,
       _headers = buildOtlpGrpcHeaders(headers),
       _timeout = timeout,
       _transport = transport ?? IoOtlpGrpcTransport(),
       _ownsTransport = transport == null,
       _compression = compression,
       _retry = retry;

  final String _endpoint;
  final Map<String, String> _headers;
  final Duration _timeout;
  final OtlpGrpcTransport _transport;

  /// Whether this exporter created [_transport] and so must release it. An
  /// injected transport belongs to whoever injected it: it may be shared
  /// with other exporters or a later SDK instance.
  final bool _ownsTransport;
  final OtlpCompression _compression;
  final OtlpRetryConfig _retry;

  @override
  Future<ExportResult> export(List<MetricData> metrics) async {
    return executeOtlpGrpcExportWithRetry(
      retry: _retry,
      onSuccessResponse: (responseBytes) => handleOtlpGrpcSuccessResponse(
        signal: 'metrics',
        responseBytes: responseBytes,
      ),
      send: () => _transport.export(
        OtlpGrpcRequest(
          uri: Uri.parse(_endpoint),
          signal: OtlpSignal.metrics,
          body: OtlpProtobufCodec.encodeMetrics(metrics),
          headers: _headers,
          timeout: _timeout,
          compression: _compression,
        ),
      ),
    );
  }

  @override
  Future<void> forceFlush() async {}

  /// Releases the transport only when this exporter created it; an injected
  /// `transport` is left open for its owner to shut down.
  @override
  Future<void> shutdown() async {
    if (_ownsTransport) {
      await _transport.shutdown();
    }
  }
}
