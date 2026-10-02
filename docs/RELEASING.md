# Releasing — comon_opentelemetry (fork Prolog)

O fluxo de release do fork, do `dev` ao pin no app. A mecânica fica no
`tool/release.sh`. Este documento explica as decisões e o que fazer quando algo sai do trilho.

> **Pin no app é por SHA completo, não pelo nome da tag.** A tag `vX.Y.Z` identifica a
> release, mas o `ref:` no `pubspec.yaml` do app é o SHA de 40 caracteres do commit
> da tag. Ver [Pin no app](#pin-no-app).

## Resumo

```bash
# 1. dev atualizada e limpa
git switch dev && git pull

# 2. rascunho: gates + CHANGELOG + diff de versão, sem escrever nada
tool/release.sh prepare 0.2.0 --dry-run

# 3. de verdade: branch release/v0.2.0 + commit de bump + PR para a main
tool/release.sh prepare 0.2.0 --ticket PL-XXXX

# 4. revisar o PR e mergear com "Create a merge commit"

# 5. tag anotada no merge commit + GitHub Release
tool/release.sh tag 0.2.0

# 6. trazer a main de volta para a dev (PR main -> dev, também com merge commit)
tool/release.sh back-merge 0.2.0 --ticket PL-XXXX

# 7. bloco pronto para o pubspec.yaml do app
tool/release.sh pin-snippet 0.2.0
```

Todo subcomando aceita `--dry-run`, que não escreve nada remoto e nem cria branch,
commit ou tag local. Rodar o mesmo subcomando duas vezes é seguro. Se o passo já
foi feito, ele diz isso e sai 0: PR já aberto, tag já no commit certo, release já
criada, `dev` já contendo a release.

## Modelo de branches e tags

| Ref | Papel | Recebe |
|---|---|---|
| `dev` | integração | PRs de `fix/*`, `feat/*` (revisados por Spark/CodeRabbit) e o back-merge da `main` |
| `main` | só releases | PRs de `release/vX.Y.Z` (vindos da `dev`) e `hotfix/vX.Y.Z` |
| `release/vX.Y.Z` | branch de release | criada pelo `prepare`, contém só o commit `chore(release): vX.Y.Z` |
| `hotfix/vX.Y.Z` | correção urgente | recortada da `main`; ver [Hotfix](#hotfix) |
| `vX.Y.Z` | tag anotada | criada pelo `tag` no merge commit da `main`. **Imutável**: nunca é movida nem apagada |

A tag `release/0.0.1-alpha.1` é herança do upstream (`serezhia`) e não segue esse
esquema. O harness só considera tags `vX.Y.Z`.

**Todo PR deste repo é mergeado com "Create a merge commit"**, nunca com squash ou
rebase. Há dois motivos:

- **Release e back-merge.** O `prepare` seguinte exige que a última tag seja ancestral
  da `dev`. Com squash, a ancestralidade se perde e o harness recusa com "back-merge pendente".
- **PRs de feature/fix para a `dev`.** O CHANGELOG é gerado das mensagens dos commits
  que o merge traz. Num squash, o commit vira o título do PR (`[PL-XXXX] ...`), que
  não é convencional. A entrada cai em "Other" e perde o tipo e o escopo.

## Pré-requisitos

- `git`, `jq` e `gh` autenticado com permissão de escrita no repo.
- Flutter na versão do `.fvmrc`, instalado via `fvm install`. O harness chama
  `~/fvm/versions/<versão>/bin/{dart,flutter}` direto, porque o wrapper `fvm` quebra
  com `resolution: workspace` (ver `CLAUDE.md`). Para trocar o binário, use `DART_BIN` e `FLUTTER_BIN`.
- Docker, só para `--with-integration`.

## Como escolher o número

Semver `X.Y.Z`, sem pre-release. A primeira release do fork é a `0.1.0`.

Enquanto a versão for `0.y.z`, o `y` faz o papel de major:

| Mudança | `0.y.z` | a partir de `1.0.0` |
|---|---|---|
| Quebra para o app (lista abaixo) | `y+1` (`0.2.0`) | `X+1` |
| Feature compatível | `z+1` ou `y+1`, a critério de quem libera | `Y+1` |
| Só correção | `z+1` | `Z+1` |

**O que conta como quebra para o app.** Considere o que o PrologFlutter usa e o que
dashboards e alertas leem:

- remoção ou renomeação de API pública, ou mudança de assinatura;
- mudança de default que altera o que é emitido: nome de span, métrica ou atributo,
  unidade, buckets de histograma, atributo que passa a ser emitido com cardinalidade
  maior. Isso quebra dashboards e alertas mesmo compilando. Cardinalidade é lei: veja o
  `CLAUDE.md`;
- dependência nova, ou major novo de uma que o app também usa (`device_info_plus`,
  `package_info_plus`, `battery_plus`, `dio`, `meta`). Isso obriga o app a casar o major;
- subir a constraint mínima de SDK (`sdk:` ou `flutter:`) acima da que o app usa.

Na dúvida, trate como quebra.

## Checklist pré-release

- [ ] Todo PR que deve entrar está mergeado na `dev`. PR aberto fica de fora; confira
      com `gh pr list --base dev`.
- [ ] `prepare --dry-run` verde. O CHANGELOG gerado foi lido: cada entrada faz sentido,
      e nenhuma quebra está escondida em `Bug fixes`.
- [ ] Se a release mexe em exporter, transport ou retry: rodar com `--with-integration`
      (precisa de Docker). O teste "collector starts late" é flaky conhecido. Se for só ele,
      rode isolado antes de concluir que é regressão.
- [ ] Se a release mexe em `comon_otel_flutter`: validação em aparelho feita no app,
      pinado no SHA candidato, antes de taguear.
- [ ] Número escolhido pela tabela acima.

## Passo a passo

### 1. `prepare`

O `prepare` recusa, com mensagem específica, quando:

- a versão não é `X.Y.Z`, ou não é maior que a dos pubspecs e que a última tag;
- o working tree está sujo, incluindo arquivo untracked;
- a tag `vX.Y.Z` já existe (local ou no `origin`), ou a branch `release/vX.Y.Z` já existe sem PR;
- o código em `HEAD` difere de `origin/dev`: os gates rodam em `HEAD` e não provariam nada;
- os três pubspecs têm versões diferentes, ou há literal de versão em `lib/` diferente
  da versão dos pubspecs (ver [Versão no código](#versão-no-código));
- existe tag `v*` que não está contida na `dev`, ou seja, back-merge pendente;
- `--with-integration` vem com `--skip-gates` ou `RELEASE_GATES_CMD`, ou nenhum pacote
  tem teste de integração;
- um gate falha.

Depois de passar, o `prepare`:

1. Roda os gates no `HEAD`: `pub get` do workspace, `analyze` dos 3 pacotes, testes
   unitários dos 3 pacotes (`dart test --exclude-tags integration` nos de Dart puro,
   `flutter test` no Flutter). Com `--with-integration`, roda também `dart test --tags integration`
   nos pacotes que têm teste com essa tag. Se nenhum tiver, o `prepare` aborta em vez de
   anunciar integração que não rodou. `--with-integration` é recusado junto com
   `--skip-gates` ou `RELEASE_GATES_CMD`, porque nesses casos a integração não roda.
2. Gera a seção do CHANGELOG a partir dos commits convencionais desde a última tag
   `v*`. Na primeira release, a base é o ponto de fork do upstream, `fbf61da`; `--since` sobrescreve.
   Os commits são agrupados por tipo. Commits trazidos por merge de PR ganham o link do
   PR, e squash merges com `(#N)` também. A soma de entradas listadas e filtradas tem de
   bater com `git rev-list --no-merges --count` do range; se não bater, o `prepare` aborta.
3. Faz o bump de versão nos 3 pubspecs e nos literais de versão em `lib/`, e confere a conservação:
   N literais antigos antes, N novos depois, zero antigos.
4. Commita `chore(release): vX.Y.Z` (com `--ticket` vira footer) numa branch
   `release/vX.Y.Z` criada a partir de `origin/dev`, faz push e abre o PR para a `main`.

`--skip-gates` só é aceito com `--dry-run` e é avisado em voz alta. Serve para ver o
CHANGELOG rápido, nunca para liberar.

### 2. Revisão e merge do PR de release

É um PR como outro qualquer: CodeRabbit e `/pr-merge-gate`. O diff é só versão e
CHANGELOG. O código já foi revisado nos PRs para a `dev`. O que revisar aqui é o
CHANGELOG e o número. **Merge com "Create a merge commit".**

**A seção gerada pode ser editada dentro deste PR**, e esse é o lugar de editar.
Exemplos: mover para "Breaking changes" uma quebra que veio sem `!`, cortar ruído ou
escrever um parágrafo de destaque. O `tag` lê o CHANGELOG do merge commit, então a
edição chega às notas do GitHub Release. Não mexa no cabeçalho `## X.Y.Z - data`: é
por ele que o `tag` acha a seção.

### 3. `tag`

O `tag` encontra o merge commit pelo PR mergeado (`release/vX.Y.Z` ou
`hotfix/vX.Y.Z`, via `gh`). Se precisar, `--commit <sha>` passa o commit direto. Antes
de criar a tag, ele confere que os pubspecs e os literais têm a versão, que o CHANGELOG
tem a seção e que o commit é o merge que trouxe a versão para a `origin/main`: está na
linha first-parent da `main`, tem dois pais e o primeiro pai ainda tem outra versão. O
commit `chore(release)` da branch e qualquer commit posterior da `main` são recusados,
com `--commit` ou via `gh`. Então cria a tag anotada, faz push e cria o GitHub Release
com a seção do CHANGELOG (`gh release create --verify-tag`).

Se a tag já existir em outro commit, o `tag` recusa: **tag nunca é movida**. Se já
existir no commit certo, só completa o que faltar.

### 4. `back-merge`

O `back-merge` garante que a `dev` contém a release. Se já contém, diz isso e sai. Se
houver PR `main -> dev` aberto, mostra o link. Se não houver, abre um. **Merge com
"Create a merge commit".** Sem esse passo, a `dev` fica com a versão antiga nos
pubspecs e o próximo `prepare` recusa.

### 5. Pin no app

```bash
tool/release.sh pin-snippet 0.2.0
```

O comando imprime o bloco dos 3 pacotes para o `pubspec.yaml` do PrologFlutter, com
`url: git@github.com:prologapp/comon_opentelemetry.git` e `path:` de cada pacote.
O `ref:` é o **SHA completo do commit da tag**, com a tag num comentário:

```yaml
  comon_otel:
    git:
      url: git@github.com:prologapp/comon_opentelemetry.git
      ref: 0123456789abcdef0123456789abcdef01234567 # v0.2.0
      path: packages/comon_otel
```

**Por que não `ref: v0.2.0`.** Os pacotes-folha (`comon_otel_dio`,
`comon_otel_flutter`) dependem do `comon_otel` por `path: ../comon_otel`. Quando o
pacote vem de git, o pub transforma esse path numa dependência git para o **SHA
resolvido** (40 caracteres). Se o app declara o `comon_otel` com outro `ref`, mesmo que
aponte para o mesmo commit, as descrições divergem e o version solving falha. Medido em
2026-10-01, `dart pub get` na 3.38.9:

```text
Because every version of comon_otel_dio from git depends on comon_otel from git
... at 61c2c5bf1e21a415d21f691f942a5c0fb97446e3 in packages/comon_otel and app_tag
depends on comon_otel from git ... at v9.9.9 in packages/comon_otel,
comon_otel_dio from git is forbidden.
```

Resultado por forma de pin: tag `v9.9.9` falha; SHA completo resolve; SHA curto falha
com o mesmo erro (é o que o commit `2c61d88f3a` do app já registrava). Como a tag é
imutável, SHA completo e tag são equivalentes, e o comentário mantém a leitura humana.

## Versão no código

Além dos pubspecs, a versão aparece como literal em `lib/`. Hoje são 25 ocorrências:
`telemetry.sdk.version` em `resource.dart`, o `user-agent` do exporter OTLP e o
`version:` de tracers e meters no dio e no flutter. O harness bumpa todas e recusa
quando alguma diverge.

Detecção de divergência: todo literal com cara de versão em `lib/` (`'X.Y.Z'` ou
`'.../X.Y.Z'`) tem de ser igual à versão dos pubspecs. Se alguém adicionar um tracer
com versão fixa diferente, o `prepare` aponta o arquivo.

**Efeito em métricas.** A versão de escopo muda a cada release. Se o collector
preserva `otel_scope_version` como label, cada release abre um conjunto novo de séries no Mimir.
O churn é limitado, um conjunto por release, mas vale saber ao ler um gráfico na
virada de versão.

Follow-up sugerido, fora deste harness: trocar os 25 literais por uma constante única
exportada pelo `comon_otel`.

## Hotfix

Para corrigir a versão em produção sem levar o que já está na `dev`:

```bash
git fetch origin
git switch -c hotfix/v0.2.1 origin/main
# fix com teste (TDD), commits convencionais
tool/release.sh prepare 0.2.1 --hotfix --dry-run
tool/release.sh prepare 0.2.1 --hotfix --ticket PL-XXXX   # bump + CHANGELOG na própria branch, push, PR -> main
# revisar, mergear com merge commit
tool/release.sh tag 0.2.1
tool/release.sh back-merge 0.2.1 --ticket PL-XXXX
```

No modo `--hotfix`, o `prepare` exige estar na branch `hotfix/vX.Y.Z` recortada da
`origin/main` atual, e exige que a versão seja patch da última tag (mesmo `X.Y`). Os
gates rodam na própria branch. O back-merge é obrigatório, senão o próximo `prepare`
da `dev` recusa.

Se o fix também precisa estar na `dev` antes do back-merge, não faça cherry-pick
manual para a `dev`. O back-merge leva o fix junto. Cherry-pick duplica o commit e
suja o CHANGELOG da próxima release.

## Rollback

- **A tag nunca é movida nem apagada.** Uma release ruim é corrigida com uma release
  nova, patch ou hotfix.
- **O app volta para a tag anterior**: `tool/release.sh pin-snippet <versão anterior>`,
  PR no app e nova build. Rollback de dependência git exige build e publicação do app,
  então é lento.
- **Primeira linha em produção é o kill-switch remoto do OTel no app**
  (`{"enabled": false}` no Remote Config), não o rollback do pin.
- O GitHub Release da versão ruim pode ganhar uma nota "não use, ver vX.Y.Z+1". A
  release não é apagada.

## O que configurar no GitHub (quando houver admin)

Hoje o fork tem `main` como branch default e o GitHub Actions desligado. Quando
houver admin:

1. **Branch default `dev`.** PRs novos já nascem contra a `dev`, e o `gh pr create`
   sem `--base` acerta.
2. **Proteção da `main`**: PR obrigatório, sem push direto nem force-push, branch
   atualizada antes do merge. O GitHub não restringe a branch de origem do PR. A regra
   "só `release/*` e `hotfix/*`" depende de quem mergeia, ou de um check de CI que falhe
   quando a head não casa `^(release|hotfix)/v`.
3. **Proteção da `dev`**: PR obrigatório, sem force-push.
4. **Métodos de merge**: deixar só "Allow merge commits" e desligar squash e rebase.
   Release, back-merge e o CHANGELOG gerado dependem disso (ver
   [Modelo de branches e tags](#modelo-de-branches-e-tags)).
5. **Ruleset de tags `v*`**: bloquear update e deletion, ou seja, tag imutável.
   Restringir criação a mantenedores. Habilitar *immutable releases*, se disponível.
6. **Actions**: ao religar, rodar em runner self-hosted (nunca `ubuntu-latest`, decisão
   do time) e manter `publish.yml`/`notify-comon-site.yml` do upstream desligados. O fork
   não publica no pub.dev. O gate da release continua local até o CI rodar de verdade.

## Problemas comuns

| Mensagem | Causa | O que fazer |
|---|---|---|
| `back-merge pendente` | a última tag não está na `dev` | `tool/release.sh back-merge <versão anterior>` e mergear com merge commit |
| `o código em HEAD difere de origin/dev` | checkout desatualizado ou com commit local | `git switch dev && git pull` |
| `literais de versão em lib/ divergem` | literal novo com versão fixa diferente | alinhar o literal com a versão dos pubspecs num PR para a `dev` |
| `CHANGELOG perdeu commits` | histórico com forma inesperada (ex.: merge octopus) | investigar o range; `--since` ajusta a base |
| `tem a versão X nos pubspecs, não Y` (no `tag`) | o PR mergeado não é o de release | conferir o PR e usar `--commit` com o merge commit certo |
| `não está na linha first-parent`, `não é merge commit` ou `não é o merge que trouxe` (no `tag`) | o commit passado não é o merge do PR de release na `main` (ex.: o `chore(release)` da branch, ou um commit posterior), ou o PR entrou por squash ou fast-forward | `--commit` com o merge commit do PR de release; se não houver merge commit, a release precisa ser refeita com "Create a merge commit" |
| gate `test ...` falhou | regressão, ou o flaky de transport | ver o log impresso; se for o flaky conhecido, rodar o teste isolado |

## Testes do harness

```bash
tool/test_release.sh                 # roda o release.sh sob /bin/bash (3.2 do macOS)
TEST_BASH=bash tool/test_release.sh  # sob o bash do PATH
```

O teste cria um repo git temporário em `$TMPDIR`, com `origin` bare local e um stub
de `gh`, e passa pelo fluxo completo:

- validação de semver;
- cada recusa, com controle positivo e negativo e asserção da mensagem;
- dry-run sem efeito em refs, HEAD e status;
- geração do CHANGELOG;
- gates reais com SDK stub;
- prepare real;
- tag;
- hotfix;
- back-merge e release seguinte;
- `pin-snippet`.

A maior parte do fluxo roda com os gates substituídos por `RELEASE_GATES_CMD`. O
caminho real dos gates também é coberto: com `RELEASE_GATES_CMD` vazio e um `HOME`
falso, o `release.sh` resolve o SDK pinado pelo `.fvmrc` em
`$HOME/fvm/versions/<versão>/bin/`, onde ficam stubs de `dart` e `flutter` que
registram diretório e argumentos de cada chamada. O teste confere `pub get`, `analyze`
e o comando de teste certo por pacote (Dart puro ou Flutter), a falha de um gate e a
falta do SDK pinado. Nenhum `dart` de verdade roda.
