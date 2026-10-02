import '../../../trace/span_data.dart';
import '../../span_exporter.dart';
import '../common/exporter_headers.dart';
import '../common/export_response.dart';
import '../common/export_retry.dart';
import '../common/http_transport.dart';
import 'protobuf_codec.dart';

/// OTLP HTTP protobuf exporter for trace data.
final class OtlpHttpProtobufSpanExporter implements SpanExporter {
  /// Creates an OTLP HTTP protobuf span exporter.
  OtlpHttpProtobufSpanExporter({
    required String endpoint,
    bool appendSignalPath = true,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    OtlpHttpTransport? transport,
    OtlpCompression compression = OtlpCompression.none,
    OtlpRetryConfig retry = const OtlpRetryConfig(),
  }) : _baseEndpoint = endpoint,
       _appendSignalPath = appendSignalPath,
       _headers = _resolveHeaders(headers, compression),
       _timeout = timeout,
       _transport = transport ?? DefaultOtlpHttpTransport(),
       _ownsTransport = transport == null,
       _compression = compression,
       _retry = retry;

  final String _baseEndpoint;
  final bool _appendSignalPath;
  final Map<String, String> _headers;
  final Duration _timeout;
  final OtlpHttpTransport _transport;

  /// Whether this exporter created [_transport] and so must release it. An
  /// injected transport belongs to whoever injected it: it may be shared
  /// with other exporters or a later SDK instance.
  final bool _ownsTransport;
  final OtlpCompression _compression;
  final OtlpRetryConfig _retry;

  @override
  Future<ExportResult> export(List<SpanData> spans) async {
    return executeOtlpExportWithRetry(
      retry: _retry,
      onSuccessResponse: (response) => handleOtlpHttpSuccessResponse(
        signal: 'traces',
        encoding: OtlpHttpResponseEncoding.protobuf,
        response: response,
      ),
      send: () => _transport.postBytes(
        OtlpHttpRequest(
          uri: _appendSignalPath
              ? resolveOtlpSignalUri(_baseEndpoint, '/v1/traces')
              : Uri.parse(_baseEndpoint),
          rawBody: OtlpProtobufCodec.encodeSpans(spans),
          headers: _headers,
          timeout: _timeout,
          compression: _compression,
        ),
      ),
    );
  }

  static Map<String, String> _resolveHeaders(
    Map<String, String>? headers,
    OtlpCompression compression,
  ) {
    return buildOtlpHttpHeaders(
      contentType: 'application/x-protobuf',
      compression: compression,
      headers: headers,
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
