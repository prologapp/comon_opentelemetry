## 0.1.0 - 2026-10-02

_Gerado por `tool/release.sh` a partir de 117 commits desde `fbf61da (ponto de fork; nenhuma tag v* ainda)`._

### Features

- **flutter:** wiring condicional do resource observer no install ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `d572c12`)
- **flutter:** observer genérico de recursos do device (storage/bateria/thermal/RSS) ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `52f0fd5`)
- **flutter:** adiciona config de métricas de recursos do device ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `14bcd43`)
- **otel:** wire session stamping and rotation into Otel.init ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `11e4048`)
- **otel:** stamp session.id on every log record in LoggerProvider ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `c48c96e`)
- **otel:** stamp session.id on every span via SessionSpanProcessor ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `558b580`)
- **otel:** add process-lifetime OtelSession identity ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `11e0260`)
- **flutter:** add recordCompletedPhase for retroactive startup phases ([#6](https://github.com/prologapp/comon_opentelemetry/pull/6), `9dc11c2`)
- **flutter:** propagate staticMetricAttributes into frame/stall metrics ([#5](https://github.com/prologapp/comon_opentelemetry/pull/5), `7d19dd5`)
- **flutter:** add startup phase spans, histogram, and startup attributes ([#5](https://github.com/prologapp/comon_opentelemetry/pull/5), `95abc1a`)
- **export-health:** expose queue depth + drop callback on batch processors ([#4](https://github.com/prologapp/comon_opentelemetry/pull/4), `0a4c715`)
- **resource:** add serviceVersion, telemetry.sdk.*, drop host.name PII (F2.1) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `dd1ea04`)
- **flutter:** stamp screen.name onto all spans (B4b) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `929728f`)
- **core:** expose batch/metric-reader knobs on Otel.init (B3) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `7ffa6d7`)

### Bug fixes

- **release:** refuse --with-integration when no integration test runs ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `6a5c990`)
- **release:** tag only the merge commit that brought the release to main ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `310615d`)
- **release:** stop the shell from globbing lib pathspecs ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `d4c778b`)
- **release:** only filter the bump commit from the CHANGELOG ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `5fdc300`)
- **otlp:** exporters only shut down the transport they created ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `9e0bdb4`)
- **batch:** share the queued drain between concurrent forceFlush calls ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `8a67075`)
- **flutter:** reject an error telemetry limit below 1 ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `00bc6a3`)
- **flutter:** never forget an error group whose window is active ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `a454389`)
- **logs:** scrub URLs in the log body before truncating it ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `557a90b`)
- **batch:** bound how long forceFlush and shutdown hold the caller ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `424bddf`)
- **flutter:** decide the error rate limit before building attributes ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `719c9ae`)
- **errors:** make scrubUrls linear by bounding the scheme length ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `7378114`)
- **limits:** cap string attribute values and log bodies at 4 KiB ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `0da9600`)
- **flutter:** rate-limit error telemetry per error group ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `3a59577`)
- **errors:** reduce URLs in error text to scheme and host ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `64466a3`)
- **flutter:** always flush on detached, once per trip on paused ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `70b09d3`)
- **flutter:** reset the thermal baseline on every new subscription ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `6d2437c`)
- **flutter:** flush once per background trip even when paused then detached ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `54c2994`)
- **flutter:** stop counting the initial thermal reading as a transition ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `26368e4`)
- **flutter:** make ComonOtelFlutter.install idempotent ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `754625c`)
- **flutter:** silence resource gauges once their observer is disposed ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `14eef39`)
- **flutter:** emit app.first_frame only when startup tracks the first frame ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `972cafd`)
- **flutter:** flush once per trip to background and never leak flush errors ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `7c244a9`)
- **flutter:** never let error telemetry skip the app's error fallback ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `87d22b7`)
- **flutter:** stop claiming platform errors as handled just because Otel is up ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `dd09548`)
- **flutter:** bound ui stall cardinality and stop measuring while backgrounded ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `f0c7718`)
- **dio:** stop re-serializing bodies on the main isolate to measure size ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `a69e1dd`)
- **dio:** stop leaking the request URL through Dio error messages ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `f66d032`)
- **metrics:** serialize concurrent forceFlush calls on an idle reader ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `7642ba7`)
- **metrics:** copy histogram bounds when the instrument is created ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `4ba88d1`)
- **metrics:** let shutdown wait for the in-flight export, bounded ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `e7a15ba`)
- **metrics:** bound how long forceFlush waits for an in-flight export ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `ce9ab3a`)
- **otlp:** parse Retry-After given as an HTTP-date ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `24d78d0`)
- **trace:** skip batch timer ticks while a flush is pending ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `8743db9`)
- **core:** isolate shutdown failures per signal and per processor ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `d035ae1`)
- **otlp:** honor Retry-After as sent and fail fast above maxRetryAfter ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `954d3c7`)
- **metrics:** keep collectAll returning a fixed-length list ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `eb6b72b`)
- **trace:** keep one size-triggered flush and cap every export batch ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `d2ac0b2`)
- **trace:** guard the host onDrop callback in batch processors ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `56a3122`)
- **metrics:** serialize periodic metric collection and export ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `f4331e2`)
- **otlp:** treat a 2xx with an unparseable body as success ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `7030a81`)
- **otlp:** cap Retry-After at the retry maxDelay ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `bd7a0ff`)
- **otlp:** abort the HTTP request when the export timeout fires ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `ef3d1c8`)
- **metrics:** isolate collect and flush failures per instrument and signal ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `c453a79`)
- **otlp:** never let a non-finite double fail a JSON export ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `a1d5ffd`)
- **metrics:** aggregate counters and histograms at record time ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `b47597c`)
- **review:** merge staticAttributes no RSS e endurece testes ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `d6f2f8c`)
- **review:** guarda erros de stream e start idempotente no resource observer ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `62a44ad`)
- **otel:** loosen meta constraint to ^1.16.0 for app SDK compatibility ([#8](https://github.com/prologapp/comon_opentelemetry/pull/8), `4a63fe4`)
- **otel:** keep OtelSession internal, not part of the public barrel ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `ad31a49`)
- **otel:** make session.id exempt from span attribute limits ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `8dbf8c6`)
- **deps:** make leaf packages consumable as git deps ([#3](https://github.com/prologapp/comon_opentelemetry/pull/3), `d5773ad`)
- **core:** swallow exporter teardown failures in forceFlush/shutdown (n1) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `ca99483`)
- **resource:** emit spec-mandatory telemetry.sdk.* by default (A1) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `507f7f1`)
- **flutter:** harden route sanitizer against query/fragment/relative names (A2) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `962f6e3`)
- **flutter:** drop umbrella route span, sanitize route names (B4a) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `ae3ee29`)
- **flutter:** flush telemetry on app background (B2) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `67a4b06`)
- **dio:** stop emitting client-side http.route (B6) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `1d380bc`)
- **dio:** never let instrumentation break the real request (B5) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `0468c4a`)
- **core:** keep batch flush chain alive after export failure (B1) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `710354b`)

### Performance

- **trace:** generate ids from a per-isolate PRNG seeded once securely ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `ec71492`)

### Documentation

- **release:** attribute squash and fast-forward tag refusals to the merge rule ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `62fd938`)
- **release:** require merge commits everywhere and allow editing the section ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `320030f`)
- **release:** document the release flow and link it ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `c4abb3b`)
- **flutter:** document the inactive blind spot of the ui stall poller ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `35a391b`)
- **session:** describe the session id as per isolate, not per process ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `98a0e44`)
- **otel:** correct session identity docs to isolate lifetime ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `be7a8e7`)
- reconcile test counts with the canonical suite (n4) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `8e009ad`)
- use $HOME instead of a machine-specific fvm path in test guidance (m3) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `bb5e992`)
- **flutter:** note service.version is runtime-conditional (n3) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `8076858`)
- **dio:** drop http.route row and de-footgun the spanNameBuilder example (m1) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `1dfb393`)
- add PR #1 review remediation spec + plan ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `2333a9d`)
- add fork CLAUDE.md + Fase 1 review/cleanup spec ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `308ae53`)
- **flutter:** make mobile init guidance composable (go-live config) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `2e0ae62`)

### Tests

- **release:** cover the real gates path and the per-package test command ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `55de82f`)
- **flutter:** keep active windows and the clock on a rejected configure ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `ec9934b`)
- **errors:** scrub the URL in an info log body ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `a3972b6`)
- **batch:** prove the exporter teardown is called under the flush budget ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `cb04642`)
- **batch:** pin the shared drain to exactly one running and one queued ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `c8b672d`)
- **flutter:** cover same-source groups and a null error telemetry limit ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `35b2802`)
- **errors:** scrub an explicit exception.message on every span path ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `c4a39f7`)
- **limits:** cover the value limit on ordinary event and link attributes ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `49d9e33`)
- **batch:** bound forceFlush and shutdown when the exporter teardown hangs ([#12](https://github.com/prologapp/comon_opentelemetry/pull/12), `6164432`)
- **flutter:** prove the ui stall poller ignores wall-clock jumps ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `a58deed`)
- **flutter:** assert one point, not just one MetricData, after reinstall ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `d73e554`)
- **trace:** id cost check uses best of 5 runs per side ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `4328221`)
- **otlp:** one transport deadline covers headers and body ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `f05597b`)
- **metrics:** assert retention is bounded by series, not measurements ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `56d33d7`)
- **metrics:** time 200 collects in the collect-cost ratio test ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `a73468e`)
- **flutter:** cobre resource observer (toggles, bateria, thermal, storage, RSS) ([#9](https://github.com/prologapp/comon_opentelemetry/pull/9), `ba2b81d`)
- **otel:** make no-rotation test call Otel.init itself ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `555baa1`)
- **otel:** cover session identity, stamping, and rotation ([#7](https://github.com/prologapp/comon_opentelemetry/pull/7), `a68c7e1`)
- **core:** assert explicit B3 flags drive batch behavior (m2) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `e4d2406`)

### Chores

- **release:** add release harness and its tests ([#13](https://github.com/prologapp/comon_opentelemetry/pull/13), `3a3d40f`)
- dart format nos arquivos tocados ([#11](https://github.com/prologapp/comon_opentelemetry/pull/11), `8335fab`)
- dart format nos arquivos tocados ([#10](https://github.com/prologapp/comon_opentelemetry/pull/10), `e73e056`)
- ignora scratch do plugin superpowers (.superpowers/) (`a85365b`)
- dart format the PR #1 remediation changes ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `6b0f6bb`)
- **flutter:** bump device_info_plus ^12 / package_info_plus ^9 to match app ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `ddd5575`)
- dart format the mobile-readiness changes ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `67cb73f`)
- pin Flutter 3.38.9 via fvm + add mobile-blockers plan/specs ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `5ab9f45`)

### Other

- test+refactor(flutter): pin iOS PII guard (systemName, not name) with a unit test (A3) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `0cc2db0`)
- test+fix: address Fase 1 review minors (M1-M5) ([#1](https://github.com/prologapp/comon_opentelemetry/pull/1), `fc9b23b`)

## 0.0.1-alpha.1

- First beta release.
- Converted the repository root into a Dart workspace managed by Melos.
- Added root workspace scripts for analyze, test, format, publish, and doc flows.
- Added repository-level contribution templates, code of conduct, and PR template.
- Added CI and manual publish GitHub Actions workflows.
- Added implementation history tracking in `IMPLEMENTATION_HISTORY.md`.
- Implemented Phase 1 tracing MVP.
- Added metrics and logging foundations with console and in-memory exporters.
- Added batch processors and a periodic metric reader.
- Added W3C trace-context propagation, W3C baggage, B3 propagation, and baggage-aware context handling.
- Added `OtelTestHelper` for in-memory testing workflows.
- Added OTLP HTTP JSON exporters and transport configuration hooks.
- Added OTEL environment variable parsing and init-time config merging.
- Added matcher helpers for span/log assertions and expanded semantic attribute constants.
- Improved OTLP JSON payload fidelity for span kinds, status codes, and histogram metrics.
- Added retry/backoff support for OTLP HTTP JSON exporters.
- Added metric and trace-id matcher helpers for tests.
- Added cumulative metric aggregation and richer histogram metric points.
- Added propagation matcher helpers for carriers, baggage, and remote span contexts.
- Added public integration contracts for database instrumentation and external logger bridges.
- Added `OtelIsolate` helpers for serializable context propagation across isolate boundaries.
- Added OTLP gzip compression support for HTTP JSON exporters.
- Added composite span, metric, and log exporters for multi-backend fan-out.
- Added per-signal OTLP endpoint support for traces, metrics, and logs.
- Added per-signal OTLP header support for traces, metrics, and logs.
- Added per-signal OTLP timeout support for traces, metrics, and logs.
- Added per-signal OTLP compression support for traces, metrics, and logs.
- Added per-signal OTLP retry support for traces, metrics, and logs.
- Made `Otel.forceFlush()` wait for pending simple span and log exports.
- Hardened W3C `traceparent` parsing to reject invalid versions, IDs, and trace flags while preserving `tracestate`.
- Added `tracestate` normalization and validation for W3C trace-context propagation.
- Added OTLP HTTP/protobuf exporters for traces, metrics, and logs.
- Added OTLP gRPC exporters and a reusable gRPC transport.
- Added a minimal OTLP protobuf encoder and binary HTTP transport support.
- Added `OTEL_EXPORTER_OTLP_PROTOCOL` support for `http/protobuf` and `grpc`.
- Added `SpanLink` support to the public tracing API and OTLP span encoders.
- Added docker-backed integration tests that raise a real OpenTelemetry Collector and verify OTLP HTTP/protobuf and gRPC end-to-end export for traces, metrics, and logs.
- Added integration coverage for per-signal OTLP HTTP endpoints, headers, compression, and timeout overrides.
- Added delayed-start retry recovery integration tests for OTLP HTTP/protobuf and OTLP gRPC.
- Reorganized exporter sources into dedicated console, in-memory, composite, and OTLP protocol folders.
- Moved shared OTLP retry and HTTP transport code into `lib/src/exporters/otlp/common/` and shortened OTLP implementation filenames.
- Added grouped public exporter barrel files for console, in-memory, composite, and OTLP imports.
- Normalized the internal source layout around `lib/src/comon_otel.dart` as the single source aggregator.
- Added folder-level barrel files throughout `src/` and kept a single public entrypoint at `lib/comon_otel.dart`.
- Added typed tracing primitives `TraceId`, `SpanId`, `TraceFlags`, and `TraceState`.
- Updated `SpanContext`, samplers, propagation, and isolate transport to use typed trace primitives internally while preserving the existing const-friendly public constructor.
- Added explicit `SpanContext.local(...)` and `SpanContext.remote(...)` factories and moved internal typed construction to those public entrypoints.
- Added matching typed/string convenience accessors on live `Span` instances.
- Added typed accessors on `SpanData` and `LogRecord` so exported models expose trace ids, span ids, flags, and state directly.
- Added matching typed/string convenience accessors on `OtelContextSnapshot` and `OtelIsolateContext`.
- Added explicit `OtelContextSnapshot.local(...)` and `OtelContextSnapshot.remote(...)` factories.
- Expanded `TraceState` with structured `TraceStateMember` parsing, key lookup, and builder helpers.
- Expanded sampler decisions with `SamplerResult`, allowing samplers to carry or modify `TraceState` during span creation.
- Added `LogRecord.current(...)` and `LogRecord.typed(...)` factories for centralized context capture and typed log correlation.
- Updated console/OTLP exporters and matcher helpers to consume typed-aware accessors from exported models.
- Updated `OtelLogger` to emit through `LogRecord.current(...)`.
- Updated isolate and propagation-oriented tests to use the new snapshot/isolate accessors.
- Updated propagation and collector integration tests to use typed-first snapshot/context factories in representative scenarios.
- Added focused tests covering typed trace primitives, structured `TraceState` members, sampler `TraceState` decisions, `SpanContext` typed accessors/factories, and `LogRecord` factories.
- Updated sampler contracts so `decide(...)` and `shouldSample(...)` receive span links, with runtime coverage proving samplers observe `SpanLink` inputs.
- Updated `TraceIdRatioSampler` to write OpenTelemetry `ot=th:...` sampling thresholds into `TraceState` for sampled spans while preserving existing `ot` subkeys.
- Split sampling results into distinct `recording` and `sampled` semantics so record-only spans can flow through processors without being exported.
- Added `AlwaysRecordSampler` and `SamplerConfig.alwaysRecord(...)`, and updated built-in span processors to export only sampled spans.
- Added `CompositeSampler` and built-in composable samplers for always-on, always-off, probability, parent-threshold, rule-based, and annotating sampling composition.
- Added sampler-driven span attributes via `SamplerResult.attributes`, and covered composite probability, rule-based, annotating, and parent-threshold behavior with runtime tests.
- Expanded `ParentBasedSampler` with configurable `remoteParentSampled`, `remoteParentNotSampled`, `localParentSampled`, and `localParentNotSampled` delegates.
- Added runtime tests covering parent-based delegate overrides for remote sampled and local not-sampled parent contexts.
- Added W3C Trace Context random trace flag support for root-span generation, continued-trace preservation, and propagation validation.
- Added public `SpanLimits` configuration with enforcement for span attributes, events, links, and nested event/link attribute limits.
- Surfaced dropped attribute/event/link counters on exported `SpanData`.
- Added `Span.addLink(...)` and `Span.addLinks(...)` for recording links after span creation while preserving order and enforcing configured link limits.
- Added runtime coverage for non-recording span ID generation and readable `instrumentationScope` access.
- Added `parentSnapshot` sampler/startSpan plumbing so custom samplers can receive full parent context, including baggage, instead of only `SpanContext`.
