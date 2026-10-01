import 'semantic_attributes.dart';

/// Matches `scheme://authority` plus everything after it up to the next
/// whitespace or quote. Over-consuming trailing text is safe (it is dropped);
/// under-consuming would leak path or query.
final RegExp _urlPattern = RegExp(
  r'''([A-Za-z][A-Za-z0-9+.\-]*)://([^\s/?#"'<>`\\]*)([^\s"'<>`]*)''',
);

/// Replaces every URL in [text] with its scheme and host only.
///
/// `https://bucket.s3.amazonaws.com/a/b?X-Amz-Signature=…` becomes
/// `https://bucket.s3.amazonaws.com/…`: path, query and fragment are dropped
/// (they carry PII such as a CPF in the path and pre-signed signatures in the
/// query), userinfo is dropped, and the port is kept. A bare origin is left
/// as is. Strings without `://` (e.g. `package:` and `dart:` stack frames)
/// are returned unchanged. The function is idempotent.
///
/// Error text (exception messages, stack traces, status descriptions,
/// diagnostics) must pass through this before it is recorded as telemetry.
String scrubUrls(String text) {
  if (!text.contains('://')) {
    return text;
  }

  return text.replaceAllMapped(_urlPattern, (match) {
    final scheme = match[1]!;
    final authority = match[2]!;
    final rest = match[3]!;
    final at = authority.lastIndexOf('@');
    final host = at < 0 ? authority : authority.substring(at + 1);
    return rest.isEmpty ? '$scheme://$host' : '$scheme://$host/…';
  });
}

/// Scrubs [value] with [scrubUrls] when [key] holds exception text
/// (`exception.message` or `exception.stacktrace`); any other attribute is
/// returned unchanged.
///
/// Applied at the SDK sinks (span attributes, span event attributes, log
/// records) so every path that records an error — `recordException`,
/// `OtelLogger.error`, log bridges, helpers — is covered at once.
Object scrubExceptionAttribute(String key, Object value) {
  if (value is String &&
      (key == SemanticAttributes.exceptionMessage ||
          key == SemanticAttributes.exceptionStacktrace)) {
    return scrubUrls(value);
  }
  return value;
}
