import 'http_transport.dart';

/// Default user-agent header used by OTLP exporters.
const String defaultOtlpUserAgent = 'OTel-OTLP-Exporter-Dart/0.1.1';

/// Builds OTLP HTTP headers for a specific content type and compression mode.
Map<String, String> buildOtlpHttpHeaders({
  required String contentType,
  required OtlpCompression compression,
  Map<String, String>? headers,
}) {
  final resolvedHeaders = Map<String, String>.from(
    headers ?? const <String, String>{},
  );
  if (!_containsHeader(resolvedHeaders, 'user-agent')) {
    resolvedHeaders['user-agent'] = defaultOtlpUserAgent;
  }

  return <String, String>{
    'content-type': contentType,
    ...resolvedHeaders,
    if (compression == OtlpCompression.gzip) 'content-encoding': 'gzip',
  };
}

/// Builds OTLP gRPC metadata headers.
Map<String, String> buildOtlpGrpcHeaders(Map<String, String>? headers) {
  final resolvedHeaders = Map<String, String>.from(
    headers ?? const <String, String>{},
  );
  if (!_containsHeader(resolvedHeaders, 'user-agent')) {
    resolvedHeaders['user-agent'] = defaultOtlpUserAgent;
  }
  return resolvedHeaders;
}

bool _containsHeader(Map<String, String> headers, String key) {
  for (final headerKey in headers.keys) {
    if (headerKey.toLowerCase() == key) {
      return true;
    }
  }
  return false;
}
