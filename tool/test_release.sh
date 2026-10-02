#!/usr/bin/env bash
# Tests for tool/release.sh. No bats: plain bash, a throwaway git repo with a
# bare "origin" under $TMPDIR, and a gh stub. Every refusal is paired with a
# positive control (same call, condition removed, succeeds) and is matched on
# its specific message, so a script that dies for an unrelated reason (syntax,
# missing tool) does not count as a correct refusal.
#
# Usage: tool/test_release.sh            (runs release.sh under /bin/bash)
#        TEST_BASH=bash tool/test_release.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/release.sh"
TEST_BASH="${TEST_BASH:-/bin/bash}"
T="$(mktemp -d "${TMPDIR:-/tmp}/release-test.XXXXXX")"
if [ -n "${KEEP_TEST_TMP:-}" ]; then
  echo "tmp mantido (KEEP_TEST_TMP): $T"
else
  trap 'rm -rf "$T"' EXIT
fi

PASS=0
FAIL=0
OUT="$T/out.txt"

# Isolate git from the developer's global/system config (hooks, signing).
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name "Release Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "release@test.invalid"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" tag.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false

# ---------------------------------------------------------------- gh stub
STUB="$T/stub"
mkdir -p "$T/bin" "$STUB"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh stub: logs every call; answers from files in $GH_STUB_DIR.
echo "gh $*" >>"$GH_STUB_DIR/calls.log"
args=" $* "
case "$args" in
  *" pr list "*"--state open"*)
    [ -f "$GH_STUB_DIR/open_pr" ] && cat "$GH_STUB_DIR/open_pr"; exit 0 ;;
  *" pr list "*"--head release/"*"--state merged"*)
    [ -f "$GH_STUB_DIR/merged_commit" ] && cat "$GH_STUB_DIR/merged_commit"; exit 0 ;;
  *" pr list "*) exit 0 ;;
  *" release view "*) [ -f "$GH_STUB_DIR/release_exists" ] && exit 0; exit 1 ;;
  *" pr create "*) echo "https://github.com/acme/fork/pull/99"; exit 0 ;;
  *" release create "*) echo "https://github.com/acme/fork/releases/tag/x"; exit 0 ;;
esac
echo "gh stub: chamada inesperada: $*" >&2
exit 3
EOF
chmod +x "$T/bin/gh"

export GH_STUB_DIR="$STUB"
export GH_BIN="$T/bin/gh"
export RELEASE_REMOTE=origin
export RELEASE_REPO_SLUG=acme/fork
export RELEASE_GIT_URL=git@example.invalid:acme/fork.git
export RELEASE_DATE=2026-01-02
export RELEASE_GATES_CMD=true

# ---------------------------------------------------------------- helpers
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
ko() {
  FAIL=$((FAIL + 1)); echo "  FAIL $1"
  echo "  ----- saída -----"; sed 's/^/  | /' "$OUT"; echo "  -----------------"
}

rel() { (cd "$W" && "$TEST_BASH" "$SCRIPT" "$@") >"$OUT" 2>&1; }

# expect_ok <name> <args...>
expect_ok() {
  local name="$1"; shift
  if rel "$@"; then ok "$name"; else ko "$name (exit $?)"; fi
}

# expect_fail <name> <message-regex> <args...>
expect_fail() {
  local name="$1" pattern="$2" rc; shift 2
  rel "$@"; rc=$?
  if [ "$rc" -ne 0 ] && grep -qE -- "$pattern" "$OUT"; then ok "$name"
  else ko "$name (exit $rc, esperado != 0 com /$pattern/)"; fi
}

# expect_out <name> <fixed-string>: the last output contains the string.
expect_out() {
  if grep -qF -- "$2" "$OUT"; then ok "$1"; else ko "$1 (faltou: $2)"; fi
}
expect_no_out() {
  if grep -qF -- "$2" "$OUT"; then ko "$1 (não devia ter: $2)"; else ok "$1"; fi
}

# Fixture git: a failing setup step aborts the run instead of silently
# turning later assertions into noise.
g() {
  git -C "$W" "$@" || { echo "SETUP FALHOU: git $*" >&2; exit 2; }
}

# Everything a dry-run must not change: refs on origin, local refs, HEAD,
# index/worktree status.
snapshot() {
  {
    git -C "$T/origin.git" for-each-ref --format='%(refname) %(objectname)'
    git -C "$W" for-each-ref --format='%(refname) %(objectname)'
    git -C "$W" rev-parse HEAD
    git -C "$W" symbolic-ref -q HEAD || true
    git -C "$W" status --porcelain --untracked-files=all
  } >"$1"
}

commit_file() { # commit_file <path> <content> <message>
  mkdir -p "$W/$(dirname "$1")"
  printf '%s\n' "$2" >"$W/$1"
  g add "$1" && g commit -q -m "$3"
}

# ---------------------------------------------------------------- fixture
git init -q --bare "$T/origin.git"
W="$T/work"
git init -q "$W"
g remote add origin "$T/origin.git"
cat >"$W/pubspec.yaml" <<'EOF'
name: _
publish_to: none
environment:
  sdk: ^3.9.0
workspace:
  - packages/core
  - packages/leaf
EOF
mkdir -p "$W/packages/core/lib/src" "$W/packages/leaf/lib"
cat >"$W/packages/core/pubspec.yaml" <<'EOF'
name: core
version: 0.0.1-alpha.1
resolution: workspace
EOF
cat >"$W/packages/core/lib/src/v.dart" <<'EOF'
const ua = 'X-Agent/0.0.1-alpha.1';
const sdk = {'sdk.version': '0.0.1-alpha.1'};
const unrelated = 'not-a-version';
EOF
cat >"$W/packages/leaf/pubspec.yaml" <<'EOF'
name: leaf
version: 0.0.1-alpha.1
resolution: workspace
dependencies:
  core:
    path: ../core
EOF
cat >"$W/packages/leaf/lib/leaf.dart" <<'EOF'
final t = getTracer('leaf', version: '0.0.1-alpha.1');
EOF
printf '## 0.0.1-alpha.1\n\n- Inherited release.\n' >"$W/CHANGELOG.md"
printf '{"flutter": "3.38.9"}\n' >"$W/.fvmrc"
g add -A && g commit -q -m "chore: initial import"
FORK_POINT="$(g rev-parse HEAD)"
export RELEASE_FALLBACK_BASE="$FORK_POINT"
g push -q origin main
g switch -q -c dev
# A PR merge (merge commit) bringing three commits, one breaking.
g switch -q -c feat/x
commit_file packages/core/lib/src/thing.dart "const thing = 1;" "feat(core): add thing"
commit_file packages/leaf/lib/old.dart "// removed" "fix(leaf)!: drop old api"
commit_file packages/core/lib/src/thing_test_note.dart "// t" "test: cover thing"
g switch -q dev
g merge -q --no-ff feat/x -m "Merge pull request #7 from acme/feat/x" -m "Add thing"
g branch -q -D feat/x
# Direct commits: a squash merge, a docs commit, a non-conventional one.
commit_file packages/core/lib/src/sq.dart "const sq = 1;" "fix: squashed fix (#9)"
commit_file README.md "readme" "docs: readme"
commit_file notes.txt "x" "Update stuff"
g push -q -u origin dev

echo "== validação de semver"
for bad in 1.2 v0.1.0 1.0.0-rc.1 01.0.0 1.0.0.0 ""; do
  expect_fail "recusa versão '$bad'" "inválida" prepare "$bad" --dry-run
done
expect_ok "controle: 0.1.0 é aceita" prepare 0.1.0 --dry-run
expect_fail "recusa versão não maior que a atual" "não é maior que a versão atual" prepare 0.0.0 --dry-run

echo "== prepare --dry-run não escreve nada"
: >"$STUB/calls.log"
snapshot "$T/before"
expect_ok "dry-run sai 0" prepare 0.1.0 --dry-run
snapshot "$T/after"
if diff -u "$T/before" "$T/after" >/dev/null; then ok "refs, HEAD e status idênticos após dry-run"
else ko "dry-run alterou estado: $(diff "$T/before" "$T/after" | tr '\n' ' ')"; fi
if grep -qE "pr create|release create" "$STUB/calls.log"; then ko "dry-run chamou gh de escrita"; else ok "dry-run não chamou gh de escrita"; fi
expect_out "imprime o comando do PR" "pr create --repo acme/fork --base main --head release/v0.1.0"

echo "== diff de versão"
expect_out "pubspec do core bumpado" "+version: 0.1.0"
expect_out "literal user-agent bumpado" "+const ua = 'X-Agent/0.1.0';"
expect_out "literal sdk.version bumpado" "+const sdk = {'sdk.version': '0.1.0'};"
expect_out "literal do tracer bumpado" "+final t = getTracer('leaf', version: '0.1.0');"
expect_no_out "literal não-versão intocado" "+const unrelated"

echo "== CHANGELOG gerado"
expect_out "cabeçalho da seção" "## 0.1.0 - 2026-01-02"
expect_out "conta os 6 commits do range" "a partir de 6 commits desde"
expect_out "breaking com escopo e link do PR" "- **leaf:** drop old api ([#7](https://github.com/acme/fork/pull/7),"
expect_out "feature com link do PR" "- **core:** add thing ([#7](https://github.com/acme/fork/pull/7),"
expect_out "squash: link do (#9) sem sufixo duplicado" "- squashed fix ([#9](https://github.com/acme/fork/pull/9),"
expect_out "commit direto sem link" "- readme (\`"
expect_out "não-convencional em Other" "- Update stuff (\`"
expect_no_out "merge commit não vira entrada" "Merge pull request"
order="$(grep -nE '^### ' "$OUT" | cut -d: -f1 | tr '\n' ' ')"
first="$(grep -nE '^### ' "$OUT" | awk -F: 'NR==1{print $2}')"
if [ "$first" = "### Breaking changes" ]; then ok "Breaking changes vem primeiro"; else ko "ordem das seções ($order): primeira é '$first'"; fi

echo "== recusa com working tree sujo"
echo "x" >"$W/untracked.txt"
expect_fail "recusa com arquivo untracked" "working tree sujo" prepare 0.1.0 --dry-run
rm "$W/untracked.txt"
echo "// edit" >>"$W/packages/core/lib/src/v.dart"
expect_fail "recusa com arquivo modificado" "working tree sujo" prepare 0.1.0 --dry-run
g checkout -q -- packages/core/lib/src/v.dart
expect_ok "controle: tree limpo passa" prepare 0.1.0 --dry-run

echo "== recusa com tag existente"
g tag -a v0.1.0 -m "v0.1.0" HEAD
expect_fail "recusa com tag local" "a tag v0.1.0 já existe localmente" prepare 0.1.0 --dry-run
g push -q origin refs/tags/v0.1.0
g tag -d v0.1.0 >/dev/null
expect_fail "recusa com tag só no origin (fetch traz)" "a tag v0.1.0 já existe" prepare 0.1.0 --dry-run
g push -q origin :refs/tags/v0.1.0
g tag -d v0.1.0 >/dev/null
expect_ok "controle: sem a tag passa" prepare 0.1.0 --dry-run

echo "== recusa quando HEAD difere de origin/dev"
commit_file packages/core/lib/src/local.dart "const l = 1;" "feat: local only"
expect_fail "recusa com commit de código não pushado" "difere de origin/dev" prepare 0.1.0 --dry-run
g reset -q --hard origin/dev
expect_ok "controle: HEAD == origin/dev passa" prepare 0.1.0 --dry-run

echo "== recusa com literal de versão divergente em lib/"
commit_file packages/leaf/lib/drift.dart "final d = getMeter('m', version: '0.0.9');" "fix: drift"
g push -q origin dev
expect_fail "recusa literal divergente" "literais de versão em lib/ divergem" prepare 0.1.0 --dry-run
g revert --no-edit HEAD >/dev/null
g push -q origin dev
expect_ok "controle: sem divergência passa" prepare 0.1.0 --dry-run

echo "== gate vermelho bloqueia"
RELEASE_GATES_CMD=false expect_fail "gate falhando aborta" "gate 'RELEASE_GATES_CMD' falhou" prepare 0.1.0 --dry-run
expect_fail "--skip-gates sem --dry-run é recusado" "só é aceito com --dry-run" prepare 0.1.0 --skip-gates
RELEASE_GATES_CMD="" expect_ok "--skip-gates no dry-run passa" prepare 0.1.0 --dry-run --skip-gates
expect_out "--skip-gates é avisado em voz alta" "GATES PULADOS"

echo "== pin-snippet antes da tag"
expect_fail "pin-snippet recusa sem tag" "a tag v0.1.0 não existe" pin-snippet 0.1.0
expect_fail "pin-snippet valida semver" "inválida" pin-snippet 0.1

echo "== prepare real (origin local + gh stub)"
: >"$STUB/calls.log"
expect_ok "prepare 0.1.0 sai 0" prepare 0.1.0 --ticket PL-1
if git -C "$T/origin.git" rev-parse -q --verify refs/heads/release/v0.1.0 >/dev/null; then ok "branch release/v0.1.0 no origin"; else ko "branch não foi pushada"; fi
REL="$(git -C "$T/origin.git" rev-parse refs/heads/release/v0.1.0 2>/dev/null)"
if [ "$(git -C "$T/origin.git" log -1 --format=%s "$REL")" = "chore(release): v0.1.0" ]; then ok "commit chore(release): v0.1.0"; else ko "mensagem do commit de release"; fi
if git -C "$T/origin.git" log -1 --format=%b "$REL" | grep -qx "PL-1"; then ok "footer PL-1 no commit"; else ko "footer do ticket ausente"; fi
if [ "$(git -C "$T/origin.git" show "$REL:packages/leaf/pubspec.yaml" | grep -c '^version: 0.1.0$')" = 1 ]; then ok "leaf/pubspec.yaml = 0.1.0 no commit"; else ko "leaf/pubspec.yaml no commit"; fi
if [ "$(git -C "$T/origin.git" grep -c "0.0.1-alpha.1" "$REL" -- packages | wc -l | tr -d ' ')" = 0 ]; then ok "nenhum 0.0.1-alpha.1 sobrou em packages/"; else ko "sobrou versão antiga em packages/"; fi
if git -C "$T/origin.git" show "$REL:CHANGELOG.md" | awk 'NR==1' | grep -qx "## 0.1.0 - 2026-01-02"; then ok "seção nova no topo do CHANGELOG"; else ko "CHANGELOG no commit"; fi
if git -C "$T/origin.git" show "$REL:CHANGELOG.md" | grep -qx "## 0.0.1-alpha.1"; then ok "seção antiga preservada"; else ko "seção antiga sumiu"; fi
if grep -qF -- "pr create --repo acme/fork --base main --head release/v0.1.0 --title [PL-1] Release v0.1.0" "$STUB/calls.log"; then ok "gh pr create com base/head/título certos"; else ko "gh pr create: $(cat "$STUB/calls.log")"; fi
echo "https://github.com/acme/fork/pull/10" >"$STUB/open_pr"
expect_ok "prepare idempotente com PR aberto" prepare 0.1.0
expect_out "diz que não há nada a fazer" "nada a fazer"
rm "$STUB/open_pr"

echo "== merge simulado do PR na main"
g switch -q main
g merge -q --no-ff release/v0.1.0 -m "Merge pull request #10 from acme/release/v0.1.0"
g push -q origin main
MERGE="$(g rev-parse HEAD)"
PRE_MERGE="$(g rev-parse HEAD^1)"
echo "$MERGE" >"$STUB/merged_commit"

echo "== tag"
expect_fail "tag recusa commit da main sem a versão" "tem a versão 0.0.1-alpha.1 nos pubspecs, não 0.1.0" tag 0.1.0 --commit "$PRE_MERGE"
snapshot "$T/before"
expect_ok "tag --dry-run sai 0" tag 0.1.0 --dry-run
snapshot "$T/after"
if diff -q "$T/before" "$T/after" >/dev/null; then ok "tag --dry-run não mudou refs"; else ko "tag --dry-run mudou refs"; fi
expect_out "tag --dry-run mostra o git tag" "[dry-run] git tag -a v0.1.0 -m comon_opentelemetry v0.1.0 $MERGE"
expect_out "notas trazem a seção do CHANGELOG" "### Features"
: >"$STUB/calls.log"
expect_ok "tag real sai 0" tag 0.1.0
if [ "$(git -C "$T/origin.git" cat-file -t refs/tags/v0.1.0 2>/dev/null)" = tag ]; then ok "tag anotada no origin"; else ko "tag não é anotada/não existe"; fi
if [ "$(git -C "$T/origin.git" rev-parse 'refs/tags/v0.1.0^{commit}')" = "$MERGE" ]; then ok "tag aponta para o merge commit"; else ko "tag no commit errado"; fi
if grep -qF -- "release create v0.1.0 --repo acme/fork --verify-tag --title v0.1.0 --notes-file" "$STUB/calls.log"; then ok "gh release create com --verify-tag"; else ko "gh release create: $(cat "$STUB/calls.log")"; fi
touch "$STUB/release_exists"
expect_ok "tag idempotente na mesma commit" tag 0.1.0
expect_out "reconhece tag já existente no commit certo" "já está em origin no commit certo"
commit_file docs.md "d" "docs: after release"
g push -q origin main
expect_fail "tag recusa mover para outro commit" "tag nunca é movida" tag 0.1.0 --commit "$(g rev-parse HEAD)"

echo "== pin-snippet"
expect_ok "pin-snippet sai 0" pin-snippet 0.1.0
expect_out "ref é o SHA completo com a tag em comentário" "      ref: $MERGE # v0.1.0"
expect_out "pacote core com path" "      path: packages/core"
expect_out "pacote leaf com path" "      path: packages/leaf"
expect_out "url do git" "      url: git@example.invalid:acme/fork.git"
expect_no_out "nunca ref: vX.Y.Z (quebra o pub)" "      ref: v0.1.0"

echo "== hotfix"
g switch -q -c hotfix/v0.1.1 origin/main
commit_file packages/core/lib/src/hot.dart "const hot = 1;" "fix(core): urgent crash"
# Same commit under a non-patch name: only the version rule can refuse it.
g switch -q -c hotfix/v0.2.0
expect_fail "hotfix recusa versão que não é patch" "hotfix deve ser patch de v0.1.0" prepare 0.2.0 --hotfix --dry-run
g switch -q hotfix/v0.1.1
g branch -q -D hotfix/v0.2.0
expect_ok "hotfix --dry-run 0.1.1 passa" prepare 0.1.1 --hotfix --dry-run
expect_out "hotfix: CHANGELOG parte da última tag" "desde \`v0.1.0\`"
expect_out "hotfix: lista o fix" "- **core:** urgent crash"
expect_no_out "hotfix: não repete a 0.1.0" "add thing"
expect_out "hotfix: bump 0.1.0 -> 0.1.1" "+version: 0.1.1"
expect_out "hotfix: PR para a main" "--base main --head hotfix/v0.1.1"
g switch -q dev
expect_fail "hotfix recusa fora da branch hotfix/vX.Y.Z" "--hotfix exige estar na branch hotfix/v0.1.1" prepare 0.1.1 --hotfix --dry-run
g branch -q -D hotfix/v0.1.1

echo "== back-merge e próxima release"
g switch -q dev
expect_fail "próximo prepare recusa sem back-merge" "back-merge pendente" prepare 0.2.0 --dry-run
: >"$STUB/calls.log"
expect_ok "back-merge --dry-run sai 0" back-merge 0.1.0 --dry-run
expect_out "back-merge imprime o PR main -> dev" "[dry-run] $GH_BIN pr create --repo acme/fork --base dev --head main"
if grep -q "pr create" "$STUB/calls.log"; then ko "back-merge dry-run chamou pr create"; else ok "back-merge dry-run não chamou pr create"; fi
g merge -q --no-ff origin/main -m "Merge pull request #11 from acme/main"
g push -q origin dev
expect_ok "back-merge reconhece dev já contendo" back-merge 0.1.0
expect_out "diz que dev já contém" "já contém v0.1.0"
commit_file packages/core/lib/src/next.dart "const n = 1;" "feat(core): next thing"
commit_file tool/x.sh "echo" "chore(release): tweak the harness"
g push -q origin dev
expect_ok "controle: prepare 0.2.0 após back-merge passa" prepare 0.2.0 --dry-run
expect_out "base do CHANGELOG é a tag anterior" "desde \`v0.1.0\`"
expect_out "commit novo listado" "- **core:** next thing"
expect_out "chore(release) que não é bump é listado" "- **release:** tweak the harness"
expect_no_out "commits da 0.1.0 não se repetem" "add thing"
expect_out "bump parte de 0.1.0" "+version: 0.2.0"
expect_fail "recusa versão não maior que a atual/última tag" "não é maior que" prepare 0.0.5 --dry-run
# With --since before the release, the range includes chore(release): v0.1.0.
expect_ok "--since no ponto de fork passa (conservação inclui o filtrado)" prepare 0.2.0 --dry-run --since "$FORK_POINT"
expect_no_out "commit de bump chore(release): v0.1.0 filtrado" "**release:** v0.1.0"
expect_out "outro chore(release) segue listado com --since" "- **release:** tweak the harness"
expect_out "--since vira o rótulo da base" "desde \`$FORK_POINT\`"

echo
# shellcheck disable=SC2016
echo "resultado: $PASS ok, $FAIL falhas (bash: $("$TEST_BASH" -c 'echo $BASH_VERSION'))"
[ "$FAIL" -eq 0 ]
