# CLAUDE.md — comon_opentelemetry (fork)

Guia o Claude Code ao trabalhar neste fork de `serezhia/comon_opentelemetry` — uma lib Dart/Flutter de OpenTelemetry, adotada como dependência git pelo app Flutter mobile da Prolog.

## Estrutura

Monorepo **melos pub-workspace** (`resolution: workspace`; `pubspec.yaml` raiz lista os pacotes + bloco `melos:`). Três pacotes:

| Pacote | Stack | Papel |
|---|---|---|
| `packages/comon_otel` | Dart puro | Core SDK — traces, metrics, logs, propagação, exporters OTLP |
| `packages/comon_otel_dio` | Dart puro | Interceptor HTTP do Dio — spans de client, propagação W3C, atributos HTTP |
| `packages/comon_otel_flutter` | Flutter | Instrumentação Flutter — navigation, lifecycle, startup, frames, interactions, errors |

## ⚠️ Toolchain — leia antes de rodar qualquer teste

**O workspace é pinado em Flutter 3.38.9 via fvm (`.fvmrc` na raiz), NÃO a default global.** Com a 3.35.7 o workspace **não resolve**: `comon_otel` tem dev_dependency `test: ^1.26.3` (min `test_api 0.7.7`), mas o `flutter_test` da 3.35.7 pina `test_api 0.7.6`. A 3.38.9 traz um `test_api` compatível e é o que o CI usa (`.github/workflows/ci.yml`).

**Bootstrap (uma vez, a partir da raiz):**
```bash
fvm dart pub get
fvm dart run melos bootstrap
```

**Rodar testes — o comando difere por pacote, porque o `fvm` tem um bug:**

- `packages/comon_otel` (Dart puro): `fvm dart test test/comon_otel_test.dart` **funciona**. (Suíte canônica: entrypoint único com `part` files expondo `defineXxxTests()`.)
- `packages/comon_otel_dio` e `packages/comon_otel_flutter`: **`fvm dart test` / `fvm flutter test` CRASHAM** — o parser de pubspec do **fvm 3.2.1** não engole o formato `resolution: workspace` (stack em `PubSpec.fromYamlString` / `Project.loadFromPath`). **Não é problema de código.** Use o binário pinado direto, de dentro do pacote:
  ```bash
  "$HOME/fvm/versions/3.38.9/bin/dart" test       # comon_otel_dio
  "$HOME/fvm/versions/3.38.9/bin/flutter" test    # comon_otel_flutter
  "$HOME/fvm/versions/3.38.9/bin/flutter" analyze # comon_otel_flutter
  ```
  É o **mesmo SDK 3.38.9** que o `.fvmrc` pina — só sem o wrapper quebrado. **Nunca** use `dart`/`flutter` pelados (pegam a SDK global errada).

**Adicionar dependência num pacote** (`resolution: workspace`): edite o `pubspec.yaml` do pacote e **re-bootstrap a partir da raiz** (`fvm dart pub get` + `fvm dart run melos bootstrap`) — não brigue com `flutter pub get` dentro do pacote. Só o `pubspec.lock` **raiz** é rastreado.

**Suítes canônicas (o que o CI roda):** `fvm dart run melos run analyze` e `fvm dart run melos run test` (= `test:dart` + `test:flutter`). Há um teste de retry/transport OTLP no core que ocasionalmente trava ~15min sob carga — se um único teste de transport pendurar, rode isolado; é pré-existente.

**Totais históricos (medidos no HEAD de `fix/mobile-readiness-blockers`, antes do fluxo de release; não remedidos no `dev`):** core 101 · dio 13 · flutter 30 · analyze limpo. Não use como gabarito: rode `melos run test`.

## Branches, PRs e release

Fluxo completo e mecânica em [`docs/RELEASING.md`](docs/RELEASING.md) (não duplicado aqui).

- **Base dos PRs é `dev`** (`fix/*`, `feat/*`). A `main` só recebe release e hotfix; o Spark não revisa PR para `main`.
- **Merge commit sempre** ("Create a merge commit"). Nunca squash nem rebase: quebra a ancestralidade da tag e o CHANGELOG.
- **Commits convencionais** (`type(scope): description`, em inglês). Eles geram o `CHANGELOG.md`; use `!` ou o footer `BREAKING CHANGE:` para quebra. Não edite `CHANGELOG.md` nem versão à mão em PR de feature.
- **Release só pelo `tool/release.sh`** (`prepare`, `tag`, `back-merge`, `pin-snippet`). Não crie tag nem bump manual. Os pacotes não são publicados no pub.dev (`publish_to: none`).
- **Nunca mover nem apagar tag `v*`.** Ela é imutável; erro em release se corrige com nova versão (ver Rollback no RELEASING.md).
- **O app (PrologFlutter) pina pelo SHA completo (40 caracteres) do commit da tag**, não pelo nome da tag, nem por branch, nem por SHA curto. O bloco pronto sai de `tool/release.sh pin-snippet X.Y.Z`.

## Impacto no app consumidor

`test` é **dev_dependency** do fork (não resolvido por quem consome). As SDK constraints dos pacotes (`sdk: ^3.9.0`, `flutter: >=3.24.0`) são satisfeitas pela 3.35.7 do app — a toolchain 3.38.9 é só pra desenvolver/testar o fork. O **único** impacto de runtime no app são deps adicionadas em `comon_otel_flutter` (`device_info_plus`, `package_info_plus`) — casar os majors do app.

## Convenções

- **Test-first.** Todo fix/feature entra por TDD (teste vermelho → implementação → verde).
- **"Telemetria nunca quebra o host":** instrumentação que pode estourar é envolta em `try { … } catch (_) {}` e o caminho normal segue (ex.: `BatchSpanProcessor._flushBatch`, interceptor Dio sempre chama `handler.next`). Reporte de erro a nível de SDK é trabalho separado (F2.2, deferido).
- **Cardinalidade é lei.** O collector da empresa dropa atributos fora da allow-list do spanmetrics e explode o Mimir com valores de alta cardinalidade. Não emitir `http.route` no client (o backend já emite o templated); sanitizar nomes de rota dinâmicos (`/order/12345` → `/order/:id`).
- **PII:** `host.name` (= nome do aparelho, "iPhone de João") é PII — em mobile, omitir `HostResourceDetector` e usar `detectMobileResourceAttributes()`. Nunca ler o campo `name` do iOS (`device_info_plus`) — é o nome do aparelho; use `systemName`.
- Comunicação com o usuário em **PT-BR**; código/identificadores/comentários em **inglês**.

## Documentos

- `docs/superpowers/specs/` — specs de design (a de mobile-readiness é `2026-06-09-...`).
- `docs/superpowers/plans/` — planos de implementação task-by-task.
- `docs/superpowers/audit/` — relatórios da auditoria multi-agente (evidência `file:line`).
