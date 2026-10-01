import 'dart:math';

import '../context/otel_context.dart';
import '../core/instrumentation_scope.dart';
import '../core/resource.dart';
import 'sampler.dart';
import 'span.dart';
import 'span_context.dart';
import 'span_kind.dart';
import 'span_link.dart';
import 'span_limits.dart';
import 'span_processor.dart';
import 'tracer.dart';
import 'span_id.dart';
import 'trace_flags.dart';
import 'trace_id.dart';

/// Creates [Tracer] instances and owns the active span processing pipeline.
final class TracerProvider {
  /// Creates a provider with the given [resource], processors, and sampler.
  TracerProvider({
    required this.resource,
    required List<SpanProcessor> spanProcessors,
    required this.sampler,
    this.spanLimits = const SpanLimits(),
  }) : _spanProcessors = List<SpanProcessor>.unmodifiable(spanProcessors);

  /// Resource attached to exported spans created by this provider.
  final Resource resource;

  /// Sampler used to decide whether new spans are recorded and sampled.
  final Sampler sampler;

  /// Limits applied to spans started through this provider.
  final SpanLimits spanLimits;
  final List<SpanProcessor> _spanProcessors;
  final Random _random = Random.secure();

  /// Returns a tracer for a specific instrumentation library or package.
  Tracer getTracer(
    String name, {
    String? version,
    String? schemaUrl,
    Map<String, Object> attributes = const <String, Object>{},
  }) {
    return Tracer(
      provider: this,
      scope: InstrumentationScope(
        name: name,
        version: version,
        schemaUrl: schemaUrl,
        attributes: attributes,
      ),
    );
  }

  /// Starts a span directly without first creating a [Tracer].
  Span startSpan({
    required InstrumentationScope instrumentationScope,
    required String name,
    SpanKind kind = SpanKind.internal,
    Map<String, Object>? attributes,
    Span? parent,
    OtelContextSnapshot? parentSnapshot,
    SpanContext? parentContext,
    List<SpanLink>? links,
    DateTime? startTime,
  }) {
    final activeContext = OtelContext.current;
    final currentParent = parent ?? OtelContext.currentSpan;
    final resolvedParentSnapshot =
        parentSnapshot ??
        (parentContext != null
            ? OtelContextSnapshot(
                spanContext: parentContext,
                baggage: activeContext.baggage,
              )
            : currentParent != null
            ? OtelContextSnapshot(
                spanContext: currentParent.spanContext,
                baggage: activeContext.baggage,
              )
            : activeContext.spanContext != null ||
                  activeContext.baggage.entries.isNotEmpty
            ? activeContext
            : null);
    final resolvedParentContext = resolvedParentSnapshot?.spanContext;
    final traceId = resolvedParentContext?.traceIdValue ?? _nextTraceId();
    final samplingResult = sampler.decide(
      traceId: traceId,
      name: name,
      kind: kind,
      parentSnapshot: resolvedParentSnapshot,
      parentContext: resolvedParentContext,
      attributes: attributes,
      links: links,
    );
    final sampled = samplingResult.sampled;
    final recording = samplingResult.recording;
    final traceFlags = TraceFlags.fromSampled(
      sampled,
      random: resolvedParentContext?.traceFlags.isRandom ?? true,
    );
    final span = Span(
      provider: this,
      scope: instrumentationScope,
      name: name,
      kind: kind,
      startTime: startTime ?? DateTime.now().toUtc(),
      spanContext: SpanContext.local(
        traceId: traceId,
        spanId: _nextSpanId(),
        traceFlags: traceFlags,
        traceState: samplingResult.traceState,
      ),
      limits: spanLimits,
      recording: recording,
      parentSpan: currentParent,
      parentSpanContext: resolvedParentContext,
      attributes: <String, Object>{
        ...?attributes,
        ...?samplingResult.attributes,
      },
      links: links,
    );

    if (recording) {
      for (final processor in _spanProcessors) {
        processor.onStart(span);
      }
    }

    return span;
  }

  /// Notifies all processors that [span] has ended.
  Future<void> onEnd(Span span) async {
    for (final processor in _spanProcessors) {
      processor.onEnd(span);
    }
  }

  /// Flushes all configured span processors.
  Future<void> forceFlush() async {
    for (final processor in _spanProcessors) {
      try {
        await processor.forceFlush();
      } catch (_) {
        // One failing processor must not keep the others from flushing.
      }
    }
  }

  /// Shuts down all configured span processors.
  Future<void> shutdown() async {
    for (final processor in _spanProcessors) {
      try {
        await processor.shutdown();
      } catch (_) {
        // One failing processor must not keep the others from shutting down.
      }
    }
  }

  TraceId _nextTraceId() => TraceId(_nextHex(32));

  SpanId _nextSpanId() => SpanId(_nextHex(16));

  String _nextHex(int length) {
    final buffer = StringBuffer();
    while (buffer.length < length) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString().substring(0, length);
  }
}
