import '../core/attribute_value_limit.dart';
import '../core/instrumentation_scope.dart';
import '../core/semantic_attributes.dart';
import '../core/url_scrubber.dart';
import 'span_id.dart';
import 'span_context.dart';
import 'span_data.dart';
import 'span_event.dart';
import 'span_kind.dart';
import 'span_link.dart';
import 'span_limits.dart';
import 'span_status.dart';
import 'trace_flags.dart';
import 'trace_id.dart';
import 'trace_state.dart';
import 'tracer_provider.dart';

/// Mutable in-memory representation of a span while it is being recorded.
final class Span {
  /// Creates a new span.
  Span({
    required TracerProvider provider,
    required this.scope,
    required this.name,
    required this.kind,
    required this.startTime,
    required this.spanContext,
    required SpanLimits limits,
    required bool recording,
    required Span? parentSpan,
    SpanContext? parentSpanContext,
    Map<String, Object>? attributes,
    List<SpanLink>? links,
  }) : _provider = provider,
       _limits = limits,
       _isRecording = recording,
       _parentSpan = parentSpan,
       _parentSpanContext = parentSpanContext {
    setAttributes(attributes ?? const <String, Object>{});
    _links.addAll(_limitLinks(links));
  }

  final TracerProvider _provider;
  final SpanLimits _limits;
  final bool _isRecording;
  final Span? _parentSpan;
  final SpanContext? _parentSpanContext;
  final Map<String, Object> _attributes = <String, Object>{};
  final Set<String> _reservedAttributeKeys = <String>{};
  final List<SpanEvent> _events = <SpanEvent>[];
  final List<SpanLink> _links = <SpanLink>[];

  final InstrumentationScope scope;
  String name;
  final SpanKind kind;
  final DateTime startTime;
  final SpanContext spanContext;

  SpanStatus _status = SpanStatus.unset;
  String? _statusDescription;
  DateTime? _endTime;
  int _droppedAttributesCount = 0;
  int _droppedEventsCount = 0;
  int _droppedLinksCount = 0;

  /// Parent span when the new span was created from an in-process context.
  Span? get parentSpan => _parentSpan;

  /// Parent span context from either an in-process or remote parent.
  SpanContext? get parentSpanContext =>
      _parentSpan?.spanContext ?? _parentSpanContext;

  /// Final span status.
  SpanStatus get status => _status;

  /// Optional description associated with [status].
  String? get statusDescription => _statusDescription;

  /// Whether [end] has been called.
  bool get hasEnded => _endTime != null;

  /// Whether this span is actively recording data.
  bool get isRecording => _isRecording;

  /// Convenience accessor for the instrumentation scope name.
  String get instrumentationScope => scope.name;

  /// Trace ID of this span.
  String get traceId => spanContext.traceId;

  /// Span ID of this span.
  String get spanId => spanContext.spanId;

  /// Parent span ID when a parent context is present.
  String? get parentSpanId => parentSpanContext?.spanId;

  /// Whether this span is marked for sampling.
  bool get sampled => spanContext.sampled;

  /// Serialized tracestate value when present.
  String? get traceState => spanContext.traceState;

  /// Typed trace ID for this span.
  TraceId get traceIdValue => spanContext.traceIdValue;

  /// Typed span ID for this span.
  SpanId get spanIdValue => spanContext.spanIdValue;

  /// Typed parent span ID when available.
  SpanId? get parentSpanIdValue => parentSpanContext?.spanIdValue;

  /// Trace flags associated with this span context.
  TraceFlags get traceFlags => spanContext.traceFlags;

  /// Typed tracestate associated with this span context.
  TraceState? get traceStateValue => spanContext.traceStateValue;

  /// Number of attributes dropped because of span limits.
  int get droppedAttributesCount => _droppedAttributesCount;

  /// Number of events dropped because of span limits.
  int get droppedEventsCount => _droppedEventsCount;

  /// Number of links dropped because of span limits.
  int get droppedLinksCount => _droppedLinksCount;

  /// Immutable snapshot of currently recorded span attributes.
  Map<String, Object> get attributes =>
      Map<String, Object>.unmodifiable(_attributes);

  /// Immutable snapshot of recorded span events.
  List<SpanEvent> get events => List<SpanEvent>.unmodifiable(_events);

  /// Immutable snapshot of recorded span links.
  List<SpanLink> get links => List<SpanLink>.unmodifiable(_links);

  /// Timestamp captured when [end] is called.
  DateTime? get endTime => _endTime;

  /// Sets a single span attribute if the span is still recording.
  ///
  /// String values longer than [SpanLimits.attributeValueLengthLimit] are
  /// truncated (see [attributeValueTruncationMarker]).
  ///
  /// Counts against [SpanLimits.attributeCountLimit] like any user
  /// attribute. Reserved keys set via [setReservedAttribute] are excluded
  /// from that count, so they never crowd out — or get crowded out by —
  /// user-supplied attributes.
  void setAttribute(String key, Object value) {
    if (hasEnded || !isRecording) {
      return;
    }

    if (_reservedAttributeKeys.contains(key)) {
      _attributes[key] = value;
      return;
    }

    final userAttributeCount =
        _attributes.length - _reservedAttributeKeys.length;
    if (!_attributes.containsKey(key) &&
        userAttributeCount >= _limits.attributeCountLimit) {
      _droppedAttributesCount += 1;
      return;
    }

    _attributes[key] = _limitValue(key, value);
  }

  /// Sets a single span attribute reserved for SDK-internal identity data
  /// (e.g. `session.id`), bypassing [SpanLimits.attributeCountLimit].
  ///
  /// Not for user-supplied instrumentation data — reserved attributes are
  /// exempt from span attribute limits so they can never be evicted by, or
  /// evict, ordinary attributes.
  void setReservedAttribute(String key, Object value) {
    if (hasEnded || !isRecording) {
      return;
    }

    _reservedAttributeKeys.add(key);
    _attributes[key] = value;
  }

  /// Sets multiple span attributes.
  void setAttributes(Map<String, Object> attributes) {
    if (hasEnded || !isRecording) {
      return;
    }

    for (final entry in attributes.entries) {
      setAttribute(entry.key, entry.value);
    }
  }

  /// Adds a span event with optional attributes and timestamp.
  void addEvent(
    String name, {
    Map<String, Object>? attributes,
    DateTime? timestamp,
  }) {
    if (hasEnded || !isRecording) {
      return;
    }

    if (_events.length >= _limits.eventCountLimit) {
      _droppedEventsCount += 1;
      return;
    }

    final sanitized = _limitAttributes(
      attributes ?? const <String, Object>{},
      _limits.attributePerEventCountLimit,
    );
    _droppedAttributesCount += sanitized.droppedCount;

    _events.add(
      SpanEvent(
        name: name,
        timestamp: timestamp ?? DateTime.now().toUtc(),
        attributes: sanitized.attributes,
      ),
    );
  }

  /// Adds a single span link.
  void addLink(SpanLink link) {
    if (hasEnded || !isRecording) {
      return;
    }

    final sanitized = _sanitizeLink(link);
    if (sanitized == null) {
      return;
    }

    _links.add(sanitized);
  }

  /// Adds multiple span links.
  void addLinks(Iterable<SpanLink> links) {
    if (hasEnded || !isRecording) {
      return;
    }

    for (final link in links) {
      addLink(link);
    }
  }

  /// Records an exception event using standard exception semantic attributes.
  ///
  /// URLs in the exception message and stack trace (derived or passed in
  /// [attributes]) are reduced to scheme and host (see [scrubUrls]).
  /// Explicit [attributes] still take precedence over the derived ones.
  void recordException(
    Object exception, {
    StackTrace? stackTrace,
    Map<String, Object>? attributes,
  }) {
    addEvent(
      'exception',
      attributes: <String, Object>{
        SemanticAttributes.exceptionType: exception.runtimeType.toString(),
        SemanticAttributes.exceptionMessage: exception.toString(),
        if (stackTrace != null)
          SemanticAttributes.exceptionStacktrace: stackTrace.toString(),
        ...?attributes,
      },
    );
  }

  /// Sets the span status.
  ///
  /// URLs in [description] are reduced to scheme and host (see [scrubUrls]):
  /// callers typically pass `error.toString()`, which may embed a full URL.
  void setStatus(SpanStatus status, {String? description}) {
    if (hasEnded || !isRecording) {
      return;
    }
    _status = status;
    _statusDescription = description == null
        ? null
        : truncateValue(
            scrubUrls(description),
            _limits.attributeValueLengthLimit,
          );
  }

  /// Replaces the span name while the span is still recording.
  void updateName(String name) {
    if (hasEnded || !isRecording) {
      return;
    }
    this.name = name;
  }

  /// Ends the span and sends it to the provider pipeline.
  Future<void> end({DateTime? endTime}) async {
    if (hasEnded) {
      return;
    }
    _endTime = endTime ?? DateTime.now().toUtc();
    await _provider.onEnd(this);
  }

  /// Converts the ended span into an immutable export payload.
  SpanData toSpanData() {
    final finalEndTime = _endTime;
    if (finalEndTime == null) {
      throw StateError('Span must be ended before it can be exported.');
    }

    return SpanData(
      name: name,
      kind: kind,
      spanContext: spanContext,
      parentSpanContext: parentSpanContext,
      status: _status,
      statusDescription: _statusDescription,
      startTime: startTime,
      endTime: finalEndTime,
      resource: _provider.resource,
      attributes: Map<String, Object>.unmodifiable(_attributes),
      events: List<SpanEvent>.unmodifiable(_events),
      links: List<SpanLink>.unmodifiable(_links),
      droppedAttributesCount: _droppedAttributesCount,
      droppedEventsCount: _droppedEventsCount,
      droppedLinksCount: _droppedLinksCount,
      scope: scope,
    );
  }

  List<SpanLink> _limitLinks(List<SpanLink>? links) {
    final source = links ?? const <SpanLink>[];
    final limited = <SpanLink>[];

    for (final link in source) {
      final sanitized = _sanitizeLink(link, currentCount: limited.length);
      if (sanitized != null) {
        limited.add(sanitized);
      }
    }

    return limited;
  }

  SpanLink? _sanitizeLink(SpanLink link, {int? currentCount}) {
    final linkCount = currentCount ?? _links.length;
    if (linkCount >= _limits.linkCountLimit) {
      _droppedLinksCount += 1;
      return null;
    }

    final sanitized = _limitAttributes(
      link.attributes,
      _limits.attributePerLinkCountLimit,
    );
    _droppedAttributesCount += sanitized.droppedCount;
    return SpanLink(context: link.context, attributes: sanitized.attributes);
  }

  /// Scrubs exception text, then applies
  /// [SpanLimits.attributeValueLengthLimit].
  Object _limitValue(String key, Object value) => limitAttributeValue(
    scrubExceptionAttribute(key, value),
    _limits.attributeValueLengthLimit,
  );

  _LimitedAttributes _limitAttributes(
    Map<String, Object> attributes,
    int limit,
  ) {
    final limited = <String, Object>{};
    var droppedCount = 0;

    for (final entry in attributes.entries) {
      if (limited.length >= limit) {
        droppedCount += 1;
        continue;
      }
      limited[entry.key] = _limitValue(entry.key, entry.value);
    }

    return _LimitedAttributes(
      attributes: Map<String, Object>.unmodifiable(limited),
      droppedCount: droppedCount,
    );
  }
}

final class _LimitedAttributes {
  const _LimitedAttributes({
    required this.attributes,
    required this.droppedCount,
  });

  final Map<String, Object> attributes;
  final int droppedCount;
}
