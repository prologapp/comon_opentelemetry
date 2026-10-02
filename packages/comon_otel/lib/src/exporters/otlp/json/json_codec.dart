import '../../../logs/log_record.dart';
import '../../../core/instrumentation_scope.dart';
import '../../../metrics/metric_data.dart';
import '../../../trace/span_data.dart';
import '../../../trace/span_link.dart';

final class OtlpJsonCodec {
  const OtlpJsonCodec._();

  static Map<String, Object?> encodeSpans(List<SpanData> spans) {
    return <String, Object?>{
      'resourceSpans': _groupByResource(spans, (batch) {
        return <String, Object?>{
          'scopeSpans': _groupByScope(batch, (scopeBatch) {
            return <String, Object?>{
              'spans': scopeBatch.map(_encodeSpan).toList(growable: false),
            };
          }),
        };
      }),
    };
  }

  static Map<String, Object?> encodeMetrics(List<MetricData> metrics) {
    return <String, Object?>{
      'resourceMetrics': _groupByResource(metrics, (batch) {
        return <String, Object?>{
          'scopeMetrics': _groupByScope(batch, (scopeBatch) {
            return <String, Object?>{
              'metrics': scopeBatch.map(_encodeMetric).toList(growable: false),
            };
          }),
        };
      }),
    };
  }

  static Map<String, Object?> encodeLogs(List<LogRecord> logs) {
    return <String, Object?>{
      'resourceLogs': _groupByResource(logs, (batch) {
        return <String, Object?>{
          'scopeLogs': _groupByScope(batch, (scopeBatch) {
            return <String, Object?>{
              'logRecords': scopeBatch.map(_encodeLog).toList(growable: false),
            };
          }),
        };
      }),
    };
  }

  static List<Map<String, Object?>> _groupByResource<T>(
    List<T> items,
    Map<String, Object?> Function(List<T> batch) builder,
  ) {
    final grouped = <String, List<T>>{};
    final resources =
        <String, ({Map<String, Object> attributes, String? schemaUrl})>{};

    for (final item in items) {
      final resource = switch (item) {
        SpanData span => span.resource,
        MetricData metric => metric.resource,
        LogRecord log => log.resource,
        _ => throw ArgumentError(
          'Unsupported OTLP item type: ${item.runtimeType}',
        ),
      };
      final key = '${resource.schemaUrl}|${resource.attributes}';
      resources[key] = (
        attributes: resource.attributes,
        schemaUrl: resource.schemaUrl,
      );
      grouped.putIfAbsent(key, () => <T>[]).add(item);
    }

    return grouped.entries
        .map((entry) {
          final payload = builder(entry.value);
          final resource = resources[entry.key]!;
          return <String, Object?>{
            'resource': <String, Object?>{
              'attributes': _encodeAttributes(resource.attributes),
            },
            if (resource.schemaUrl != null) 'schemaUrl': resource.schemaUrl,
            ...payload,
          };
        })
        .toList(growable: false);
  }

  static List<Map<String, Object?>> _groupByScope<T>(
    List<T> items,
    Map<String, Object?> Function(List<T> batch) builder,
  ) {
    final grouped = <InstrumentationScope, List<T>>{};

    for (final item in items) {
      final scope = switch (item) {
        SpanData span =>
          span.scope ?? const InstrumentationScope(name: 'default'),
        MetricData metric =>
          metric.scope ?? const InstrumentationScope(name: 'default'),
        LogRecord log => InstrumentationScope(
          name: log.loggerName ?? 'default',
        ),
        _ => const InstrumentationScope(name: 'default'),
      };
      grouped.putIfAbsent(scope, () => <T>[]).add(item);
    }

    return grouped.entries
        .map((entry) {
          final payload = builder(entry.value);
          return <String, Object?>{
            'scope': _encodeScope(entry.key),
            if (entry.key.schemaUrl != null) 'schemaUrl': entry.key.schemaUrl,
            ...payload,
          };
        })
        .toList(growable: false);
  }

  static Map<String, Object?> _encodeScope(InstrumentationScope scope) {
    return <String, Object?>{
      'name': scope.name,
      if (scope.version != null) 'version': scope.version,
      if (scope.attributes.isNotEmpty)
        'attributes': _encodeAttributes(scope.attributes),
    };
  }

  static Map<String, Object?> _encodeSpan(SpanData span) {
    return <String, Object?>{
      'traceId': span.traceId,
      'spanId': span.spanId,
      if (span.parentSpanId != null) 'parentSpanId': span.parentSpanId,
      'name': span.name,
      'kind': _encodeSpanKind(span.kind.name),
      'startTimeUnixNano': _toUnixNanos(span.startTime),
      'endTimeUnixNano': _toUnixNanos(span.endTime),
      'attributes': _encodeAttributes(span.attributes),
      'events': span.events
          .map(
            (event) => <String, Object?>{
              'name': event.name,
              'timeUnixNano': _toUnixNanos(event.timestamp),
              'attributes': _encodeAttributes(event.attributes),
            },
          )
          .toList(growable: false),
      'links': span.links.map(_encodeSpanLink).toList(growable: false),
      'status': <String, Object?>{
        'code': _encodeStatus(span.status.name),
        ...?switch (span.statusDescription) {
          final String statusDescription => <String, Object?>{
            'message': statusDescription,
          },
          _ => null,
        },
      },
    };
  }

  static Map<String, Object?> _encodeSpanLink(SpanLink link) {
    return <String, Object?>{
      'traceId': link.context.traceId,
      'spanId': link.context.spanId,
      ...?switch (link.context.traceState) {
        final String traceState => <String, Object?>{'traceState': traceState},
        _ => null,
      },
      'attributes': _encodeAttributes(link.attributes),
    };
  }

  static Map<String, Object?> _encodeMetric(MetricData metric) {
    final payload = switch (metric.instrumentType) {
      MetricInstrumentType.counter => <String, Object?>{
        'sum': <String, Object?>{
          'aggregationTemporality': _encodeTemporality(
            metric.aggregationTemporality,
          ),
          'isMonotonic': metric.isMonotonic ?? true,
          'dataPoints': metric.points
              .map(_encodeNumberDataPoint)
              .toList(growable: false),
        },
      },
      MetricInstrumentType.observableCounter => <String, Object?>{
        'sum': <String, Object?>{
          'aggregationTemporality': _encodeTemporality(
            metric.aggregationTemporality,
          ),
          'isMonotonic': metric.isMonotonic ?? true,
          'dataPoints': metric.points
              .map(_encodeNumberDataPoint)
              .toList(growable: false),
        },
      },
      MetricInstrumentType.upDownCounter => <String, Object?>{
        'sum': <String, Object?>{
          'aggregationTemporality': _encodeTemporality(
            metric.aggregationTemporality,
          ),
          'isMonotonic': metric.isMonotonic ?? false,
          'dataPoints': metric.points
              .map(_encodeNumberDataPoint)
              .toList(growable: false),
        },
      },
      MetricInstrumentType.observableGauge => <String, Object?>{
        'gauge': <String, Object?>{
          'dataPoints': metric.points
              .map(_encodeNumberDataPoint)
              .toList(growable: false),
        },
      },
      MetricInstrumentType.histogram => <String, Object?>{
        'histogram': <String, Object?>{
          'aggregationTemporality': _encodeTemporality(
            metric.aggregationTemporality,
          ),
          'dataPoints': metric.points
              .map(_encodeHistogramDataPoint)
              .toList(growable: false),
        },
      },
    };

    return <String, Object?>{
      'name': metric.name,
      ...?metric.description == null
          ? null
          : <String, Object?>{'description': metric.description},
      ...?metric.unit == null ? null : <String, Object?>{'unit': metric.unit},
      ...payload,
    };
  }

  static Map<String, Object?> _encodeLog(LogRecord log) {
    return <String, Object?>{
      'timeUnixNano': _toUnixNanos(log.timestamp),
      if (log.observedTimestamp case final observed?)
        'observedTimeUnixNano': _toUnixNanos(observed),
      ...?switch (log.traceId) {
        final String traceId => <String, Object?>{'traceId': traceId},
        _ => null,
      },
      ...?switch (log.spanId) {
        final String spanId => <String, Object?>{'spanId': spanId},
        _ => null,
      },
      'severityNumber': log.severity.value,
      ...?log.severityText == null
          ? null
          : <String, Object?>{'severityText': log.severityText},
      'body': <String, Object?>{'stringValue': log.body},
      'attributes': _encodeAttributes(log.attributes),
    };
  }

  static List<Map<String, Object?>> _encodeAttributes(
    Map<String, Object> attributes,
  ) {
    return attributes.entries
        .map((entry) {
          return <String, Object?>{
            'key': entry.key,
            'value': _encodeAnyValue(entry.value),
          };
        })
        .toList(growable: false);
  }

  static Map<String, Object?> _encodeAnyValue(Object value) {
    if (value is String) {
      return <String, Object?>{'stringValue': value};
    }
    if (value is bool) {
      return <String, Object?>{'boolValue': value};
    }
    if (value is int) {
      return <String, Object?>{'intValue': value.toString()};
    }
    if (value is double) {
      return <String, Object?>{'doubleValue': _encodeDouble(value)};
    }
    if (value is List) {
      return <String, Object?>{
        'arrayValue': <String, Object?>{
          'values': value
              .map((item) => _encodeAnyValue(item as Object))
              .toList(growable: false),
        },
      };
    }
    return <String, Object?>{'stringValue': value.toString()};
  }

  /// Encodes a double per the proto3 JSON mapping: finite values stay JSON
  /// numbers, while NaN and +/-Infinity become the strings "NaN",
  /// "Infinity" and "-Infinity". `jsonEncode` throws on non-finite numbers,
  /// which would otherwise fail the whole export batch.
  static Object _encodeDouble(double value) {
    if (value.isFinite) {
      return value;
    }
    if (value.isNaN) {
      return 'NaN';
    }
    return value.isNegative ? '-Infinity' : 'Infinity';
  }

  static String _toUnixNanos(DateTime timestamp) {
    final micros = timestamp.toUtc().microsecondsSinceEpoch;
    return '${micros}000';
  }

  static int _encodeSpanKind(String kind) {
    switch (kind) {
      case 'internal':
        return 1;
      case 'server':
        return 2;
      case 'client':
        return 3;
      case 'producer':
        return 4;
      case 'consumer':
        return 5;
      default:
        return 0;
    }
  }

  static int _encodeStatus(String status) {
    switch (status) {
      case 'ok':
        return 1;
      case 'error':
        return 2;
      default:
        return 0;
    }
  }

  static Map<String, Object?> _encodeNumberDataPoint(MetricPoint point) {
    return <String, Object?>{
      'attributes': _encodeAttributes(point.attributes),
      'timeUnixNano': _toUnixNanos(point.timestamp),
      if (point.startTimestamp case final startTimestamp?)
        'startTimeUnixNano': _toUnixNanos(startTimestamp),
      if (point.value case final int value)
        'asInt': value
      else if (point.value case final double value)
        'asDouble': _encodeDouble(value)
      else
        'asDouble': point.value,
    };
  }

  static Map<String, Object?> _encodeHistogramDataPoint(MetricPoint point) {
    return <String, Object?>{
      'attributes': _encodeAttributes(point.attributes),
      'timeUnixNano': _toUnixNanos(point.timestamp),
      if (point.startTimestamp case final startTimestamp?)
        'startTimeUnixNano': _toUnixNanos(startTimestamp),
      'count': point.count ?? 0,
      'sum': _encodeDouble(point.sum ?? 0.0),
      if (point.min case final min?) 'min': _encodeDouble(min),
      if (point.max case final max?) 'max': _encodeDouble(max),
      'bucketCounts': point.bucketCounts ?? const <int>[],
      'explicitBounds': (point.explicitBounds ?? const <double>[])
          .map(_encodeDouble)
          .toList(growable: false),
    };
  }

  static int _encodeTemporality(AggregationTemporality temporality) {
    switch (temporality) {
      case AggregationTemporality.delta:
        return 1;
      case AggregationTemporality.cumulative:
        return 2;
      case AggregationTemporality.unspecified:
        return 0;
    }
  }
}
