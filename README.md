# comon_opentelemetry

OpenTelemetry SDK workspace for Dart and Flutter.

This repository contains the core SDK, Flutter instrumentation, and Dio client
instrumentation in a single Dart workspace managed with Melos.

## Packages

| Package | Purpose | Location |
| --- | --- | --- |
| `comon_otel` | Core SDK: traces, metrics, logs, context propagation, OTLP exporters | `packages/comon_otel` |
| `comon_otel_flutter` | Flutter lifecycle, navigation, startup, performance, and error instrumentation | `packages/comon_otel_flutter` |
| `comon_otel_dio` | Dio client spans, propagation, and HTTP attribute capture | `packages/comon_otel_dio` |

## Getting Started

### Workspace setup

```bash
dart pub get
melos bootstrap
```

### Common commands

```bash
melos run analyze
melos run test
melos run format
melos run publish:dry-run
```

## Which Package Should You Use?

- Use `comon_otel` if you need the core SDK in a Dart backend, CLI, or shared library.
- Use `comon_otel_flutter` if you want Flutter app telemetry on top of the core SDK.
- Use `comon_otel_dio` if your app already uses Dio and you want client request spans.

## Architecture Overview

```text
comon_otel
├─ comon_otel_flutter
└─ comon_otel_dio
```

- `comon_otel` is the shared foundation.
- `comon_otel_flutter` adds app-side Flutter signals.
- `comon_otel_dio` adds HTTP client instrumentation for Dio.

## End-to-End Demo

The repository also includes a collector-backed demo under
`demo/otel_end_to_end`:

- `backend/`: a Dart HTTP service instrumented with `comon_otel`
- `frontend/`: linked to the Flutter example application
- `docker-compose.yml`: local collector and Jaeger stack

Start the demo stack from the repository root:

```bash
docker compose -f demo/otel_end_to_end/docker-compose.yml up -d --build
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, validation commands, and pull
request expectations.

## Releasing

Releases are cut from `dev` into `main` and tagged `vX.Y.Z` with
`tool/release.sh`. See [docs/RELEASING.md](docs/RELEASING.md) (PT-BR) for the full
flow, versioning rules, hotfix, rollback and how the app pins a release.

## License

This repository is distributed under the MIT License. See [LICENSE](LICENSE).
