import '../core/attribute_value_limit.dart';
import '../core/otel_session.dart';
import '../core/resource.dart';
import '../core/semantic_attributes.dart';
import '../core/url_scrubber.dart';
import 'log_limits.dart';
import 'log_processor.dart';
import 'log_record.dart';
import 'otel_logger.dart';

/// Owns loggers and dispatches records through configured processors.
final class LoggerProvider {
  /// Creates a logger provider with [resource] and [logProcessors].
  LoggerProvider({
    required this.resource,
    required List<LogProcessor> logProcessors,
    this.logLimits = const LogLimits(),
  }) : _logProcessors = List<LogProcessor>.unmodifiable(logProcessors);

  /// Resource attached to emitted log records.
  final Resource resource;

  /// Limits applied to every emitted record.
  final LogLimits logLimits;
  final List<LogProcessor> _logProcessors;

  /// Returns a logger with the given [name].
  OtelLogger getLogger(String name) {
    return OtelLogger(provider: this, name: name);
  }

  /// Sends [record] through every configured log processor.
  ///
  /// Exception text (`exception.message`, `exception.stacktrace`) has its
  /// URLs reduced to scheme and host (see [scrubUrls]), whichever path
  /// produced the record ([OtelLogger.error], a log bridge, a raw [emit]).
  /// String attribute values and the body are then cut to [logLimits]
  /// (see [attributeValueTruncationMarker]).
  ///
  /// Every record is stamped with the isolate's `session.id` first. Log
  /// records are immutable value objects and [LogProcessor.onEmit] fans out
  /// to every configured processor with the same instance (unlike spans,
  /// there is no in-place mutation or per-processor chaining) — so the
  /// stamping happens here, at the single funnel point all records pass
  /// through, rather than as a `LogProcessor` entry in the list.
  void emit(LogRecord record) {
    final stamped = _stampSession(record);
    for (final processor in _logProcessors) {
      processor.onEmit(stamped);
    }
  }

  LogRecord _stampSession(LogRecord record) {
    return LogRecord(
      timestamp: record.timestamp,
      observedTimestamp: record.observedTimestamp,
      severity: record.severity,
      severityText: record.severityText,
      body: truncateValue(record.body, logLimits.bodyLengthLimit),
      resource: record.resource,
      spanContext: record.spanContext,
      loggerName: record.loggerName,
      attributes: <String, Object>{
        for (final entry in record.attributes.entries)
          entry.key: limitAttributeValue(
            scrubExceptionAttribute(entry.key, entry.value),
            logLimits.attributeValueLengthLimit,
          ),
        SemanticAttributes.sessionId: OtelSession.id,
      },
    );
  }

  /// Flushes all configured log processors.
  Future<void> forceFlush() async {
    for (final processor in _logProcessors) {
      try {
        await processor.forceFlush();
      } catch (_) {
        // One failing processor must not keep the others from flushing.
      }
    }
  }

  /// Shuts down all configured log processors.
  Future<void> shutdown() async {
    for (final processor in _logProcessors) {
      try {
        await processor.shutdown();
      } catch (_) {
        // One failing processor must not keep the others from shutting down.
      }
    }
  }
}
