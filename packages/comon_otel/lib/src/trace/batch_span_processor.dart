import 'dart:async';
import 'dart:collection';

import '../exporters/span_exporter.dart';
import 'span.dart';
import 'span_data.dart';
import 'span_processor.dart';

final class BatchSpanProcessor implements SpanProcessor {
  BatchSpanProcessor({
    required SpanExporter exporter,
    this.maxBatchSize = 512,
    this.scheduleDelay = const Duration(seconds: 5),
    this.maxQueueSize = 2048,
    this.exportTimeout,
    this.onDrop,
  }) : _exporter = exporter {
    _timer = Timer.periodic(scheduleDelay, (_) {
      unawaited(_flushBatch());
    });
  }

  final SpanExporter _exporter;
  final int maxBatchSize;
  final Duration scheduleDelay;
  final int maxQueueSize;
  final Duration? exportTimeout;

  /// Invoked once for each span evicted because the queue reached
  /// [maxQueueSize]. Lets the host observe export saturation (drop count).
  final void Function()? onDrop;

  final Queue<SpanData> _queue = Queue<SpanData>();

  /// Current number of spans buffered awaiting export.
  int get queueLength => _queue.length;

  Timer? _timer;
  bool _isShutdown = false;
  Future<void> _pendingFlush = Future<void>.value();

  @override
  void onStart(Span span) {}

  @override
  void onEnd(Span span) {
    if (_isShutdown || !span.isRecording || !span.sampled) {
      return;
    }

    if (_queue.length >= maxQueueSize) {
      _queue.removeFirst();
      try {
        onDrop?.call();
      } catch (_) {
        // A host callback must never break the processor nor the caller.
      }
    }
    _queue.addLast(span.toSpanData());

    if (_queue.length >= maxBatchSize) {
      unawaited(_flushBatch());
    }
  }

  @override
  Future<void> forceFlush() async {
    await _flushBatch(all: true);
    try {
      await _exporter.forceFlush();
    } catch (_) {
      // Telemetry teardown must never throw into the host. SDK-level error
      // reporting is tracked separately (F2.2, out of scope here).
    }
  }

  @override
  Future<void> shutdown() async {
    if (_isShutdown) {
      return;
    }
    _isShutdown = true;
    _timer?.cancel();
    await _flushBatch(all: true);
    try {
      await _exporter.shutdown();
    } catch (_) {
      // See forceFlush: teardown failures are swallowed by design.
    }
  }

  Future<void> _flushBatch({bool all = false}) {
    _pendingFlush = _pendingFlush.then((_) async {
      try {
        if (_queue.isEmpty) {
          return;
        }

        do {
          final batch = <SpanData>[];
          final limit = all ? _queue.length : maxBatchSize;
          while (_queue.isNotEmpty && batch.length < limit) {
            batch.add(_queue.removeFirst());
          }

          if (batch.isNotEmpty) {
            final exportFuture = _exporter.export(batch);
            if (exportTimeout == null) {
              await exportFuture;
            } else {
              await exportFuture.timeout(exportTimeout!);
            }
          }
        } while (all && _queue.isNotEmpty);
      } catch (_) {
        // Swallow export failures so the flush chain never becomes a
        // permanently-rejected Future. SDK-level error reporting is tracked
        // separately (F2.2, out of scope here).
      }
    });

    return _pendingFlush;
  }
}
