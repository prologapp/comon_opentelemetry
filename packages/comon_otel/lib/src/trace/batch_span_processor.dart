import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

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
    this.flushWaitLimit = const Duration(seconds: 2),
    this.onDrop,
  }) : _exporter = exporter {
    _timer = Timer.periodic(scheduleDelay, (_) {
      // Skip the tick while a flush is queued or running: it will export
      // what is queued, and queueing one cycle per tick behind a slow export
      // would only grow the flush chain.
      if (_queuedFlushes > 0) {
        return;
      }
      unawaited(_flushBatch());
    });
  }

  final SpanExporter _exporter;
  final int maxBatchSize;
  final Duration scheduleDelay;
  final int maxQueueSize;
  final Duration? exportTimeout;

  /// Tempo máximo que [forceFlush] e [shutdown] seguram o chamador. Cobre o
  /// flush inteiro (exports em fila mais o forceFlush/shutdown do exporter),
  /// não só um export já em voo: por isso não é o `inFlightWaitLimit` do
  /// `PeriodicMetricReader`, embora a semântica seja a mesma (espera limitada,
  /// nenhum erro propagado, export em voo não cancelado).
  ///
  /// Estourado o prazo, o chamador segue e o flush continua em segundo plano,
  /// do jeito que já rodava: o processador não cancela o export em voo, só
  /// deixa de aguardá-lo. Enquanto os exports concluem, o restante da fila é
  /// exportado e, no [shutdown], o exporter só é desligado depois do último.
  /// Um export que falha ou estoura [exportTimeout] encerra o ciclo ali, como
  /// antes: o restante fica na fila (no [shutdown], perdido) e o exporter é
  /// desligado com aquele export possivelmente ainda em voo.
  ///
  /// Padrão de 2 s, o mesmo do `PeriodicMetricReader`. Sem prazo, um coletor
  /// que aceita e não responde segurava o chamador por 30 s (shutdown) e até
  /// 122 s (forceFlush de 1.536 spans = 12 exports seriais); e como
  /// `Otel.forceFlush`/`Otel.shutdown` percorrem traces, métricas e logs em
  /// série, um flush de traces travado atrasava o de logs pelo mesmo tempo.
  final Duration flushWaitLimit;

  /// Invoked once for each span evicted because the queue reached
  /// [maxQueueSize]. Lets the host observe export saturation (drop count).
  final void Function()? onDrop;

  final Queue<SpanData> _queue = Queue<SpanData>();

  /// Current number of spans buffered awaiting export.
  int get queueLength => _queue.length;

  Timer? _timer;
  bool _isShutdown = false;
  Future<void> _pendingFlush = Future<void>.value();
  int _queuedFlushes = 0;
  bool _sizeFlushScheduled = false;
  Future<void>? _queuedDrain;

  /// Number of flush cycles queued or running. Test-only: lets tests assert
  /// that the flush chain stays bounded while an export is slow. With an
  /// export stuck, forceFlush/shutdown contribute at most two (one running,
  /// one queued); a size-triggered cycle can add one more.
  @visibleForTesting
  int get queuedFlushCount => _queuedFlushes;

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

    // One size-triggered flush at a time: it keeps draining full batches,
    // so scheduling another per item would only grow the flush chain while
    // an export is slow.
    if (_queue.length >= maxBatchSize && !_sizeFlushScheduled) {
      _sizeFlushScheduled = true;
      unawaited(_flushBatch(sizeTriggered: true));
    }
  }

  @override
  /// Exporta a fila e faz o forceFlush do exporter, esperando no máximo
  /// [flushWaitLimit]; ver o campo.
  ///
  /// Chamadas concorrentes compartilham o ciclo de drenagem que ainda não
  /// começou: com um export travado, N chamadas deixam no máximo um ciclo
  /// rodando e um na fila, não N. O da fila exporta o que chegou depois do
  /// início do ciclo em andamento.
  Future<void> forceFlush() => _waitBounded(() async {
    await _drainAll();
    try {
      await _exporter.forceFlush();
    } catch (_) {
      // Telemetry teardown must never throw into the host. SDK-level error
      // reporting is tracked separately (F2.2, out of scope here).
    }
  });

  @override
  /// Para o processador, exporta a fila e desliga o exporter, esperando no
  /// máximo [flushWaitLimit]; ver o campo.
  Future<void> shutdown() async {
    if (_isShutdown) {
      return;
    }
    _isShutdown = true;
    _timer?.cancel();
    await _waitBounded(() async {
      await _drainAll();
      try {
        await _exporter.shutdown();
      } catch (_) {
        // See forceFlush: teardown failures are swallowed by design.
      }
    });
  }

  /// Aguarda [body] por no máximo [flushWaitLimit]. Estourado o prazo, [body]
  /// segue rodando sem ser aguardado. Nunca lança: [body] já engole as
  /// próprias falhas, e o timeout é engolido aqui.
  Future<void> _waitBounded(Future<void> Function() body) async {
    try {
      await body().timeout(flushWaitLimit);
    } catch (_) {
      // Telemetria nunca lança no host; o prazo estourado não é erro.
    }
  }

  /// Returns the drain-all cycle that is queued and not yet started,
  /// queueing one if there is none. A cycle that already started may have
  /// passed its last queue check, so items emitted after it started get the
  /// next one.
  Future<void> _drainAll() => _queuedDrain ??= _flushBatch(all: true);

  /// Queues one flush cycle on the chain. Every export carries at most
  /// [maxBatchSize] items. A timer cycle exports one batch; a
  /// size-triggered cycle drains while a full batch is queued; [all]
  /// drains the whole queue (forceFlush/shutdown).
  Future<void> _flushBatch({bool all = false, bool sizeTriggered = false}) {
    _queuedFlushes += 1;
    _pendingFlush = _pendingFlush.then((_) async {
      if (all) {
        // Started: callers arriving from now on queue the next drain.
        _queuedDrain = null;
      }
      try {
        while (_queue.isNotEmpty) {
          final batch = <SpanData>[];
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
