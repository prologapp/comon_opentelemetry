import '../core/otel_session.dart';
import '../core/resource.dart';
import '../core/semantic_attributes.dart';
import 'log_processor.dart';
import 'log_record.dart';
import 'otel_logger.dart';

/// Owns loggers and dispatches records through configured processors.
final class LoggerProvider {
  /// Creates a logger provider with [resource] and [logProcessors].
  LoggerProvider({
    required this.resource,
    required List<LogProcessor> logProcessors,
  }) : _logProcessors = List<LogProcessor>.unmodifiable(logProcessors);

  /// Resource attached to emitted log records.
  final Resource resource;
  final List<LogProcessor> _logProcessors;

  /// Returns a logger with the given [name].
  OtelLogger getLogger(String name) {
    return OtelLogger(provider: this, name: name);
  }

  /// Sends [record] through every configured log processor.
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
      body: record.body,
      resource: record.resource,
      spanContext: record.spanContext,
      loggerName: record.loggerName,
      attributes: <String, Object>{
        ...record.attributes,
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
      await processor.shutdown();
    }
  }
}
