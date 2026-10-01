import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../exporters/log_exporter.dart';
import 'log_processor.dart';
import 'log_record.dart';

/// Log processor that buffers records and exports them in batches.
final class BatchLogProcessor implements LogProcessor {
  /// Creates a batch log processor.
  BatchLogProcessor({
    required LogExporter exporter,
    this.maxBatchSize = 512,
    this.scheduleDelay = const Duration(seconds: 1),
    this.maxQueueSize = 2048,
    this.exportTimeout,
    this.onDrop,
  }) : _exporter = exporter {
    _timer = Timer.periodic(scheduleDelay, (_) {
      unawaited(_flushBatch());
    });
  }

  final LogExporter _exporter;

  /// Maximum number of records exported in one batch.
  final int maxBatchSize;

  /// Delay between scheduled batch exports.
  final Duration scheduleDelay;

  /// Maximum number of queued records retained before dropping oldest items.
  final int maxQueueSize;

  /// Optional timeout applied to each export operation.
  final Duration? exportTimeout;

  /// Invoked once for each record evicted because the queue reached
  /// [maxQueueSize]. Lets the host observe export saturation (drop count).
  final void Function()? onDrop;

  final Queue<LogRecord> _queue = Queue<LogRecord>();

  /// Current number of records buffered awaiting export.
  int get queueLength => _queue.length;

  Timer? _timer;
  bool _isShutdown = false;
  Future<void> _pendingFlush = Future<void>.value();
  int _queuedFlushes = 0;
  bool _sizeFlushScheduled = false;

  /// Number of flush cycles queued or running. Test-only: lets tests assert
  /// that the flush chain stays bounded while an export is slow.
  @visibleForTesting
  int get queuedFlushCount => _queuedFlushes;

  @override
  /// Queues [record] for batched export.
  void onEmit(LogRecord record) {
    if (_isShutdown) {
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
    _queue.addLast(record);

    // One size-triggered flush at a time: it keeps draining full batches,
    // so scheduling another per item would only grow the flush chain while
    // an export is slow.
    if (_queue.length >= maxBatchSize && !_sizeFlushScheduled) {
      _sizeFlushScheduled = true;
      unawaited(_flushBatch(sizeTriggered: true));
    }
  }

  @override
  /// Flushes queued records and then flushes the exporter.
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
  /// Stops the processor, flushes queued records, and shuts down the exporter.
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

  /// Queues one flush cycle on the chain. Every export carries at most
  /// [maxBatchSize] items. A timer cycle exports one batch; a
  /// size-triggered cycle drains while a full batch is queued; [all]
  /// drains the whole queue (forceFlush/shutdown).
  Future<void> _flushBatch({bool all = false, bool sizeTriggered = false}) {
    _queuedFlushes += 1;
    _pendingFlush = _pendingFlush.then((_) async {
      try {
        while (_queue.isNotEmpty) {
          final batch = <LogRecord>[];
          // A non-positive maxBatchSize falls back to one export per cycle.
          final batchLimit = maxBatchSize > 0 ? maxBatchSize : _queue.length;
          while (_queue.isNotEmpty && batch.length < batchLimit) {
            batch.add(_queue.removeFirst());
          }

          final exportFuture = _exporter.export(batch);
          if (exportTimeout == null) {
            await exportFuture;
          } else {
            await exportFuture.timeout(exportTimeout!);
          }

          final keepDraining =
              all || (sizeTriggered && _queue.length >= maxBatchSize);
          if (!keepDraining) {
            break;
          }
        }
      } catch (_) {
        // Swallow export failures so the flush chain never becomes a
        // permanently-rejected Future. SDK-level error reporting is tracked
        // separately (F2.2, out of scope here).
      } finally {
        // Lowered in the same synchronous step as the last queue check, so
        // an item that fills a batch afterwards always schedules a new cycle.
        if (sizeTriggered) {
          _sizeFlushScheduled = false;
        }
        _queuedFlushes -= 1;
      }
    });

    return _pendingFlush;
  }
}
