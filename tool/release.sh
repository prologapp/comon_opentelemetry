#!/usr/bin/env bash
# Release harness for the comon_opentelemetry fork.
#
# Flow (see docs/RELEASING.md): dev -> release/vX.Y.Z PR -> main -> annotated
# tag vX.Y.Z on the merge commit -> GitHub Release -> back-merge main -> dev
# -> app pin.
#
# Subcommands:
#   prepare <X.Y.Z>      gates + version bump + CHANGELOG section + release PR
#   tag <X.Y.Z>          annotated tag on the merged release commit + GitHub Release
#   back-merge <X.Y.Z>   make sure dev contains the release (PR main -> dev)
#   pin-snippet <X.Y.Z>  pubspec.yaml block for the app
#
# Flags:
#   --dry-run            never writes anything remote, never creates branches,
#                        commits or tags locally; prints what would happen
#   --hotfix             prepare: release from the current hotfix/vX.Y.Z branch
#                        (cut from origin/main) instead of origin/dev
#   --with-integration   prepare: also run the Docker-backed integration tests
#   --skip-gates         prepare --dry-run only: skip analyze/test (loudly)
#   --since <ref>        prepare: CHANGELOG base override
#   --ticket <PL-XXXX>   prepare/back-merge: PR title prefix and commit footer
#   --commit <sha>       tag: release commit override (instead of asking gh)
#
# Environment overrides (mainly for tool/test_release.sh):
#   RELEASE_REMOTE, RELEASE_DEV_BRANCH, RELEASE_MAIN_BRANCH, RELEASE_REPO_SLUG,
#   RELEASE_GIT_URL, RELEASE_FALLBACK_BASE, RELEASE_DATE, RELEASE_GATES_CMD,
#   GH_BIN, DART_BIN, FLUTTER_BIN
#
# Compatible with the macOS system bash (3.2): no associative arrays, no
# mapfile, no ${var,,}; files are rewritten via temp file + mv (no sed -i).

set -euo pipefail
# No pathname expansion: git pathspecs such as 'pkg/lib/*.dart' are passed
# unquoted and must reach git verbatim (the shell would expand them to the
# top-level lib files only and silently skip lib/src).
set -f
if [ -n "${RELEASE_TRACE:-}" ]; then set -x; fi

REMOTE="${RELEASE_REMOTE:-origin}"
DEV_BRANCH="${RELEASE_DEV_BRANCH:-dev}"
MAIN_BRANCH="${RELEASE_MAIN_BRANCH:-main}"
REPO_SLUG="${RELEASE_REPO_SLUG:-prologapp/comon_opentelemetry}"
GIT_URL="${RELEASE_GIT_URL:-git@github.com:prologapp/comon_opentelemetry.git}"
# CHANGELOG base used only while no vX.Y.Z tag exists (i.e. the first
# release): the commit where this fork diverged from serezhia/main.
FALLBACK_BASE="${RELEASE_FALLBACK_BASE:-fbf61da09a12dab29528d0bbcce1b82c86d8b2e1}"
GH="${GH_BIN:-gh}"

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# Version-shaped string literals in lib/ code: 'X.Y.Z[-pre]' or '.../X.Y.Z[-pre]'.
LITERAL_RE="['/][0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?'"

DRY_RUN=0
HOTFIX=0
WITH_INTEGRATION=0
SKIP_GATES=0
SINCE=""
TICKET=""
COMMIT_OVERRIDE=""
WORK=""

# ---------------------------------------------------------------- utilities

die() {
  echo "ERRO: $*" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
  exit 2
}

info() { echo "==> $*"; }
warn() { echo "AVISO: $*" >&2; }

cleanup() {
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT

run_or_print() {
  # Prints the command in dry-run, runs it otherwise.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  [dry-run] $*"
  else
    "$@"
  fi
}

validate_semver() {
  local v="$1"
  [[ "$v" =~ $SEMVER_RE ]] || die "versão '$v' inválida: use X.Y.Z (semver sem prefixo 'v' e sem pre-release)"
}

# ver_cmp A B -> prints -1, 0 or 1. Handles an optional -prerelease suffix
# (a prerelease sorts before the same core version; two prereleases compare
# lexically, which is enough for the inherited 0.0.1-alpha.1).
ver_cmp() {
  local a="$1" b="$2" a_core b_core a_pre="" b_pre="" i x y
  a_core="${a%%-*}"; b_core="${b%%-*}"
  [ "$a_core" != "$a" ] && a_pre="${a#*-}"
  [ "$b_core" != "$b" ] && b_pre="${b#*-}"
  local IFS=.
  # shellcheck disable=SC2206
  local aa=($a_core) bb=($b_core)
  for i in 0 1 2; do
    x="${aa[$i]:-0}"; y="${bb[$i]:-0}"
    if [ "$x" -gt "$y" ]; then echo 1; return; fi
    if [ "$x" -lt "$y" ]; then echo -1; return; fi
  done
  if [ -z "$a_pre" ] && [ -z "$b_pre" ]; then echo 0; return; fi
  if [ -z "$a_pre" ]; then echo 1; return; fi
  if [ -z "$b_pre" ]; then echo -1; return; fi
  if [ "$a_pre" = "$b_pre" ]; then echo 0
  elif [ "$(printf '%s\n%s\n' "$a_pre" "$b_pre" | LC_ALL=C sort | awk 'NR==1')" = "$a_pre" ]; then echo -1
  else echo 1
  fi
}

# Workspace members (paths) listed in the root pubspec.yaml at <ref>.
packages_at() {
  git show "$1:pubspec.yaml" | awk '
    /^workspace:/ { inws = 1; next }
    inws && /^[^[:space:]-]/ { inws = 0 }
    inws && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print }'
}

pubspec_version_of() {
  # Reads the top-level `version:` from pubspec content on stdin.
  sed -n 's/^version:[[:space:]]*//p' | awk 'NR==1' | tr -d "\"'" | sed 's/[[:space:]]*$//'
}

# Prints the single version shared by every workspace package at <ref>, or dies.
workspace_version_at() {
  local ref="$1" pkg v first=""
  for pkg in $(packages_at "$ref"); do
    v="$(git show "$ref:$pkg/pubspec.yaml" | pubspec_version_of)"
    [ -n "$v" ] || die "$pkg/pubspec.yaml sem 'version:' em $ref"
    if [ -z "$first" ]; then first="$v"
    elif [ "$v" != "$first" ]; then
      die "versões divergentes entre os pacotes em $ref ($first vs $pkg=$v); alinhe os pubspecs antes de prosseguir"
    fi
  done
  [ -n "$first" ] || die "nenhum pacote encontrado no 'workspace:' do pubspec.yaml raiz em $ref"
  echo "$first"
}

lib_pathspecs_at() {
  local pkg
  for pkg in $(packages_at "$1"); do echo "$pkg/lib/*.dart"; done
}

# Distinct version-shaped literals found in lib/ at <ref>.
lib_literals_at() {
  local ref="$1"
  # shellcheck disable=SC2046
  { git grep -h -o -E "$LITERAL_RE" "$ref" -- $(lib_pathspecs_at "$ref") || true; } \
    | sed -E "s|^['/]||; s|'\$||" | LC_ALL=C sort -u
}

# Occurrences of the literal <version> ('V' or /V') in lib/ at <ref>.
lib_literal_count_at() {
  local ref="$1" v="$2"
  # shellcheck disable=SC2046
  { git grep -h -o -F -e "'$v'" -e "/$v'" "$ref" -- $(lib_pathspecs_at "$ref") || true; } | wc -l | tr -d ' '
}

lib_literal_files_at() {
  local ref="$1" v="$2"
  # shellcheck disable=SC2046
  { git grep -l -F -e "'$v'" -e "/$v'" "$ref" -- $(lib_pathspecs_at "$ref") || true; } | sed "s|^$ref:||"
}

# Dies unless every version-shaped literal in lib/ at <ref> equals <version>.
assert_literals_match() {
  local ref="$1" v="$2" lit bad=""
  for lit in $(lib_literals_at "$ref"); do
    [ "$lit" = "$v" ] || bad="$bad $lit"
  done
  [ -z "$bad" ] || die "literais de versão em lib/ divergem do pubspec ($v) em $ref:$bad — corrija antes (git grep -nE \"$LITERAL_RE\" -- 'packages/*/lib/*.dart')"
}

regex_escape() {
  # Versions only contain [0-9A-Za-z.-] (validated); only '.' is special.
  printf '%s' "$1" | sed 's/\./\\./g'
}

ensure_clean_tree() {
  local dirty
  dirty="$(git status --porcelain --untracked-files=normal)"
  [ -z "$dirty" ] || die "working tree sujo; commite ou descarte antes:
$dirty"
}

fetch_remote() {
  info "git fetch --tags $REMOTE"
  git fetch --quiet --tags "$REMOTE" || die "git fetch --tags $REMOTE falhou"
}

remote_ref_exists() {
  git ls-remote --exit-code "$REMOTE" "$1" >/dev/null 2>&1
}

local_tag_commit() {
  git rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null || true
}

remote_tag_commit() {
  # Peeled commit of an annotated tag, or the target of a lightweight one.
  local out
  out="$(git ls-remote "$REMOTE" "refs/tags/$1^{}" 2>/dev/null | awk 'NR==1{print $1}')"
  [ -n "$out" ] || out="$(git ls-remote "$REMOTE" "refs/tags/$1" 2>/dev/null | awk 'NR==1{print $1}')"
  echo "$out"
}

latest_v_tag() {
  # Highest vX.Y.Z tag, optionally restricted to those merged into <ref>.
  if [ -n "${1:-}" ]; then
    git tag -l 'v[0-9]*' --merged "$1" --sort=-v:refname
  else
    git tag -l 'v[0-9]*' --sort=-v:refname
  fi | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' | awk 'NR==1' || true
}

resolve_tool() {
  # resolve_tool <dart|flutter> -> absolute path to the pinned binary.
  local name="$1" override="" fv
  if [ "$name" = dart ]; then override="${DART_BIN:-}"; else override="${FLUTTER_BIN:-}"; fi
  if [ -n "$override" ]; then echo "$override"; return; fi
  [ -f .fvmrc ] || die ".fvmrc ausente; defina DART_BIN e FLUTTER_BIN"
  fv="$(jq -r '.flutter // empty' .fvmrc)"
  [ -n "$fv" ] || die ".fvmrc sem a chave 'flutter'"
  local bin="$HOME/fvm/versions/$fv/bin/$name"
  [ -x "$bin" ] || die "$bin não existe; rode 'fvm install $fv' (o wrapper fvm quebra com resolution: workspace, por isso o binário pinado é chamado direto)"
  echo "$bin"
}

# ---------------------------------------------------------------- gates

run_gate() {
  # run_gate <label> <dir> <cmd...>; logs to $WORK/gates/<n>.log
  local label="$1" dir="$2"; shift 2
  local log
  GATE_N=$((GATE_N + 1))
  log="$WORK/gates/$GATE_N.log"
  printf '  %-48s ' "$label"
  if (cd "$dir" && "$@") >"$log" 2>&1; then
    echo "ok"
  else
    echo "FALHOU"
    echo "----- últimas linhas de $label -----" >&2
    tail -40 "$log" >&2
    die "gate '$label' falhou; release abortada"
  fi
}

run_gates() {
  mkdir -p "$WORK/gates"
  GATE_N=0
  if [ "$SKIP_GATES" -eq 1 ]; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!  GATES PULADOS (--skip-gates): nada foi analisado nem testado  !!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    return
  fi
  if [ -n "${RELEASE_GATES_CMD:-}" ]; then
    info "gates customizados (RELEASE_GATES_CMD)"
    run_gate "RELEASE_GATES_CMD" . bash -c "$RELEASE_GATES_CMD"
    return
  fi
  local dart flutter pkg
  dart="$(resolve_tool dart)"
  flutter="$(resolve_tool flutter)"
  info "gates locais (dart: $dart)"
  run_gate "pub get (workspace)" . "$dart" pub get
  for pkg in $(packages_at HEAD); do
    run_gate "analyze $pkg" "$pkg" "$dart" analyze .
  done
  for pkg in $(packages_at HEAD); do
    if grep -qE '^[[:space:]]+sdk:[[:space:]]*flutter' "$pkg/pubspec.yaml"; then
      run_gate "test $pkg" "$pkg" "$flutter" test
    else
      run_gate "test $pkg (sem integração)" "$pkg" "$dart" test --exclude-tags integration
    fi
  done
  if [ "$WITH_INTEGRATION" -eq 1 ]; then
    command -v docker >/dev/null 2>&1 || die "--with-integration exige Docker"
    for pkg in $(packages_at HEAD); do
      if [ -d "$pkg/test" ] && grep -rqF "'integration'" "$pkg/test"; then
        run_gate "test $pkg (integração, Docker)" "$pkg" "$dart" test --tags integration
      fi
    done
  else
    echo "  integração com Docker: não rodada (use --with-integration; 'collector starts late' é flaky conhecido)"
  fi
}

# ---------------------------------------------------------------- changelog

# Emits one TSV line per commit: group, scope, description, pr, sha.
classify_commit() {
  local sha="$1" pr="$2" subject body type scope bang desc group
  subject="$(git log -1 --format=%s "$sha")"
  body="$(git log -1 --format=%b "$sha")"
  # Only the bump commit made by `prepare` is noise; other chore(release)
  # commits (e.g. changes to this harness) are listed.
  local bump_re='^chore\(release\): v[0-9]+\.[0-9]+\.[0-9]+$'
  if [[ "$subject" =~ $bump_re ]]; then
    FILTERED=$((FILTERED + 1))
    return
  fi
  local re='^([A-Za-z]+)(\(([^)]*)\))?(!)?:[[:space:]]+(.+)$'
  if [[ "$subject" =~ $re ]]; then
    type="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    scope="${BASH_REMATCH[3]}"
    bang="${BASH_REMATCH[4]}"
    desc="${BASH_REMATCH[5]}"
    case "$type" in
      feat) group=2 ;; fix) group=3 ;; perf) group=4 ;; refactor) group=5 ;;
      docs) group=6 ;; test) group=7 ;; build|ci) group=8 ;; style|chore) group=9 ;;
      revert) group=3 ;; *) group=10; scope=""; desc="$subject" ;;
    esac
    if [ -n "$bang" ] || printf '%s\n' "$body" | grep -qE '^BREAKING[ -]CHANGE:'; then
      group=1
    fi
  else
    group=10; scope=""; desc="$subject"
  fi
  # Squash merges carry "(#N)" in the subject: keep the link, drop the suffix.
  if [ -z "$pr" ] && [[ "$desc" =~ \(#([0-9]+)\)$ ]]; then
    pr="${BASH_REMATCH[1]}"
  fi
  desc="$(printf '%s' "$desc" | sed -E 's/[[:space:]]*\(#[0-9]+\)$//')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$scope" "$desc" "$pr" "$(git rev-parse --short=7 "$sha")"
}

# generate_changelog_section <base> <head> <version> <out-file>
# Walks the first-parent history of <head>: a PR merge contributes the commits
# it brought in (linked to the PR); a direct commit contributes itself.
generate_changelog_section() {
  local base="$1" head="$2" version="$3" out="$4" c parents pr subj x
  local entries="$WORK/entries.tsv"
  : >"$entries"
  FILTERED=0
  for c in $(git rev-list --first-parent "$base..$head"); do
    parents="$(git rev-list --parents -n1 "$c" | awk '{print NF-1}')"
    subj="$(git log -1 --format=%s "$c")"
    pr=""
    if [[ "$subj" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then pr="${BASH_REMATCH[1]}"; fi
    if [ "$parents" -ge 2 ]; then
      [ "$parents" -eq 2 ] || die "merge octopus em $c não é suportado pelo gerador de CHANGELOG"
      for x in $(git rev-list --no-merges "$c^2" "^$c^1" "^$base"); do
        classify_commit "$x" "$pr" >>"$entries"
      done
    else
      classify_commit "$c" "" >>"$entries"
    fi
  done

  # Conservation: every non-merge commit in the range is either listed or
  # explicitly filtered. A mismatch means the walk above missed commits.
  local expected listed
  expected="$(git rev-list --no-merges --count "$base..$head")"
  listed="$(grep -c . "$entries" || true)"
  if [ "$((listed + FILTERED))" -ne "$expected" ]; then
    die "CHANGELOG perdeu commits: $listed listados + $FILTERED filtrados != $expected no range $base..$head"
  fi
  CHANGELOG_LISTED="$listed"

  local date="${RELEASE_DATE:-$(date +%Y-%m-%d)}" g title
  {
    echo "## $version - $date"
    echo
    echo "_Gerado por \`tool/release.sh\` a partir de $expected commits desde \`$BASE_LABEL\`._"
    for g in 1 2 3 4 5 6 7 8 9 10; do
      case "$g" in
        1) title="Breaking changes" ;; 2) title="Features" ;; 3) title="Bug fixes" ;;
        4) title="Performance" ;; 5) title="Refactoring" ;; 6) title="Documentation" ;;
        7) title="Tests" ;; 8) title="Build and CI" ;; 9) title="Chores" ;; 10) title="Other" ;;
      esac
      if awk -F'\t' -v g="$g" '$1 == g { found = 1 } END { exit !found }' "$entries"; then
        echo
        echo "### $title"
        echo
        awk -F'\t' -v g="$g" -v slug="$REPO_SLUG" '
          $1 == g {
            line = "- "
            if ($2 != "") line = line "**" $2 ":** "
            line = line $3
            if ($4 != "") line = line " ([#" $4 "](https://github.com/" slug "/pull/" $4 "), `" $5 "`)"
            else line = line " (`" $5 "`)"
            print line
          }' "$entries"
      fi
    done
  } >"$out"
}

# insert_changelog_section <changelog-file> <section-file> <version>
insert_changelog_section() {
  local file="$1" section="$2" version="$3" tmp
  tmp="$file.tmp.$$"
  if [ -f "$file" ] && grep -qE "^## $(regex_escape "$version")( |$)" "$file"; then
    die "CHANGELOG.md já tem a seção $version"
  fi
  if [ ! -f "$file" ]; then
    { cat "$section"; } >"$tmp"
  else
    awk -v sec="$section" '
      !done && /^## / { while ((getline l < sec) > 0) print l; print ""; done = 1 }
      { print }
      END { if (!done) { print ""; while ((getline l < sec) > 0) print l } }' "$file" >"$tmp"
  fi
  mv "$tmp" "$file"
}

# Extracts the "## <version>" section (without its heading) from stdin.
extract_changelog_section() {
  awk -v v="$1" '
    index($0, "## " v " ") == 1 || $0 == "## " v { on = 1; next }
    on && /^## / { exit }
    on { print }'
}

# ---------------------------------------------------------------- bump

# apply_bump <base-sha> <target-dir> <old> <new>
# Materializes the files to change from <base-sha> into <target-dir> and
# rewrites them. Prints the changed paths (relative), one per line.
apply_bump() {
  local base="$1" dir="$2" old="$3" new="$4" pkg f old_re
  old_re="$(regex_escape "$old")"
  for pkg in $(packages_at "$base"); do
    f="$pkg/pubspec.yaml"
    mkdir -p "$dir/$(dirname "$f")"
    git show "$base:$f" | sed -E "s/^version:[[:space:]]*.*$/version: $new/" >"$dir/$f.tmp.$$"
    mv "$dir/$f.tmp.$$" "$dir/$f"
    echo "$f"
  done
  for f in $(lib_literal_files_at "$base" "$old"); do
    mkdir -p "$dir/$(dirname "$f")"
    git show "$base:$f" | sed -E "s|(['/])$old_re'|\\1$new'|g" >"$dir/$f.tmp.$$"
    mv "$dir/$f.tmp.$$" "$dir/$f"
    echo "$f"
  done
}

literal_count_in_file() {
  { grep -o -F -e "'$2'" -e "/$2'" "$1" || true; } | wc -l | tr -d ' '
}

# Verifies the bump in <dir> for the given file list (conservation of literals).
verify_bump() {
  local dir="$1" files="$2" old="$3" new="$4" n_old_before="$5" f v n_old n_new
  n_old=0; n_new=0
  for f in $files; do
    case "$f" in
      */pubspec.yaml)
        v="$(pubspec_version_of <"$dir/$f")"
        [ "$v" = "$new" ] || die "bump não aplicado em $f ($v)"
        ;;
      *)
        n_old=$((n_old + $(literal_count_in_file "$dir/$f" "$old")))
        n_new=$((n_new + $(literal_count_in_file "$dir/$f" "$new")))
        ;;
    esac
  done
  [ "$n_old" -eq 0 ] || die "sobraram $n_old literais '$old' em lib/ após o bump"
  [ "$n_new" -eq "$n_old_before" ] || die "literais não conservados: $n_old_before '$old' antes, $n_new '$new' depois"
}

# ---------------------------------------------------------------- prepare

cmd_prepare() {
  local version="$1" tag="v$1" branch="release/v$1"
  [ "$HOTFIX" -eq 1 ] && branch="hotfix/v$1"
  validate_semver "$version"
  ensure_clean_tree
  fetch_remote

  # Source of the release: origin/dev for a regular release; the current
  # hotfix/vX.Y.Z branch (cut from origin/main, fixes committed) for a hotfix.
  local dev_ref base_sha
  if [ "$HOTFIX" -eq 1 ]; then
    dev_ref="$branch"
    [ "$(git symbolic-ref --short -q HEAD || true)" = "$branch" ] \
      || die "--hotfix exige estar na branch $branch (crie com: git switch -c $branch $REMOTE/$MAIN_BRANCH, commite o fix e rode de novo)"
    git merge-base --is-ancestor "$REMOTE/$MAIN_BRANCH" HEAD \
      || die "$branch não contém $REMOTE/$MAIN_BRANCH atual; recorte o hotfix da $MAIN_BRANCH atualizada"
    base_sha="$(git rev-parse HEAD)"
  else
    dev_ref="$REMOTE/$DEV_BRANCH"
    base_sha="$(git rev-parse -q --verify "$dev_ref^{commit}")" || die "$dev_ref não existe"
  fi

  [ -z "$(local_tag_commit "$tag")" ] || die "a tag $tag já existe localmente"
  if remote_ref_exists "refs/tags/$tag"; then die "a tag $tag já existe em $REMOTE"; fi

  # Idempotency: a release PR already open means prepare already ran.
  local open_pr
  open_pr="$("$GH" pr list --repo "$REPO_SLUG" --head "$branch" --base "$MAIN_BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -n "$open_pr" ]; then
    info "$branch já preparada: PR aberto em $open_pr — nada a fazer"
    return 0
  fi
  if [ "$HOTFIX" -eq 0 ]; then
    if git rev-parse -q --verify "refs/heads/$branch" >/dev/null; then
      die "a branch local $branch já existe (sem PR aberto); apague-a ou conclua à mão"
    fi
    if remote_ref_exists "refs/heads/$branch"; then
      die "a branch $branch já existe em $REMOTE sem PR aberto; abra o PR à mão ou apague a branch"
    fi
    # The gates run on HEAD, so HEAD's code must be exactly what dev releases.
    local code_paths
    code_paths="$(packages_at "$base_sha" | tr '\n' ' ') pubspec.yaml pubspec.lock .fvmrc"
    # shellcheck disable=SC2086
    if ! git diff --quiet "$base_sha" HEAD -- $code_paths; then
      die "o código em HEAD difere de $dev_ref ($(git rev-parse --short "$base_sha")); os gates não provariam nada. Atualize a partir de $dev_ref (git switch $DEV_BRANCH && git pull)"
    fi
  fi

  local current
  current="$(workspace_version_at "$base_sha")"
  assert_literals_match "$base_sha" "$current"

  # CHANGELOG base: last vX.Y.Z tag merged into the source; the global latest
  # tag must be merged too, otherwise a back-merge is pending and the section
  # would repeat the previous release.
  local last_merged last_global base
  last_merged="$(latest_v_tag "$base_sha")"
  last_global="$(latest_v_tag)"
  if [ -n "$last_global" ] && [ "$last_global" != "$last_merged" ]; then
    die "$last_global não está contida em $dev_ref: back-merge pendente (tool/release.sh back-merge ${last_global#v})"
  fi
  if [ "$HOTFIX" -eq 1 ]; then
    [ -n "$last_merged" ] || die "hotfix exige uma release anterior (nenhuma tag v* em $branch)"
    local last_plain="${last_merged#v}"
    [ "${version%.*}" = "${last_plain%.*}" ] \
      || die "hotfix deve ser patch de $last_merged (mesmo X.Y); $version não é"
  fi
  if [ -n "$SINCE" ]; then
    base="$(git rev-parse -q --verify "$SINCE^{commit}")" || die "--since $SINCE não resolve"
    BASE_LABEL="$SINCE"
  elif [ -n "$last_merged" ]; then
    base="$last_merged"; BASE_LABEL="$last_merged"
  else
    base="$(git rev-parse -q --verify "$FALLBACK_BASE^{commit}")" || die "nenhuma tag v* e RELEASE_FALLBACK_BASE ($FALLBACK_BASE) não resolve; use --since <ref>"
    BASE_LABEL="$(git rev-parse --short "$base") (ponto de fork; nenhuma tag v* ainda)"
  fi
  git merge-base --is-ancestor "$base" "$base_sha" || die "a base do CHANGELOG ($BASE_LABEL) não é ancestral de $dev_ref"

  [ "$(ver_cmp "$version" "$current")" = 1 ] || die "$version não é maior que a versão atual dos pubspecs ($current)"
  if [ -n "$last_merged" ]; then
    [ "$(ver_cmp "$version" "${last_merged#v}")" = 1 ] || die "$version não é maior que a última tag ($last_merged)"
  fi

  local n_old
  n_old="$(lib_literal_count_at "$base_sha" "$current")"
  # The SDK reports its version in telemetry, so lib/ always carries at least
  # one literal. Zero means the search is broken, not that there is nothing
  # to bump: refuse instead of passing vacuously.
  [ "$n_old" -gt 0 ] || die "nenhum literal '$current' encontrado em lib/ em $dev_ref; a busca de literais está quebrada (ou a versão sumiu do código)"
  info "release $tag a partir de $dev_ref @ $(git rev-parse --short "$base_sha"): $current -> $version ($n_old literais em lib/)"

  run_gates

  WORK_SECTION="$WORK/section.md"
  generate_changelog_section "$base" "$base_sha" "$version" "$WORK_SECTION"

  local target files f
  if [ "$DRY_RUN" -eq 1 ]; then
    target="$WORK/b"
    mkdir -p "$target"
  elif [ "$HOTFIX" -eq 1 ]; then
    target="$(git rev-parse --show-toplevel)"
  else
    info "git switch -c $branch $dev_ref"
    git switch --quiet -c "$branch" "$dev_ref"
    target="$(git rev-parse --show-toplevel)"
  fi
  files="$(apply_bump "$base_sha" "$target" "$current" "$version")"
  verify_bump "$target" "$files" "$current" "$version" "$n_old"
  if git cat-file -e "$base_sha:CHANGELOG.md" 2>/dev/null; then
    git show "$base_sha:CHANGELOG.md" >"$target/CHANGELOG.md"
  else
    rm -f "$target/CHANGELOG.md"
  fi
  insert_changelog_section "$target/CHANGELOG.md" "$WORK_SECTION" "$version"
  files="$files
CHANGELOG.md"

  local title="Release $tag"
  [ -n "$TICKET" ] && title="[$TICKET] $title"
  local body="$WORK/pr-body.md" nfiles gates_desc="analyze + testes unitários verdes"
  nfiles="$(echo "$files" | grep -c .)"
  [ "$SKIP_GATES" -eq 1 ] && gates_desc="PULADOS (--skip-gates)"
  [ -n "${RELEASE_GATES_CMD:-}" ] && gates_desc="customizados (RELEASE_GATES_CMD)"
  [ "$WITH_INTEGRATION" -eq 1 ] && gates_desc="$gates_desc + integração Docker"
  {
    echo "Release \`$tag\` do fork: \`$dev_ref\` -> \`$MAIN_BRANCH\`."
    echo
    echo "- Versão: \`$current\` -> \`$version\` em $nfiles arquivos (pubspecs, literais de versão em lib/ e CHANGELOG.md)."
    echo "- Gates locais: $gates_desc."
    echo
    echo "**Merge com \"Create a merge commit\"** (não squash/rebase). Depois do merge: \`tool/release.sh tag $version\` e \`tool/release.sh back-merge $version\`."
    echo
    cat "$WORK_SECTION"
  } >"$body"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "================ diff de versão que seria aplicado ================"
    local a="$WORK/a"
    for f in $files; do
      [ "$f" = CHANGELOG.md ] && continue
      mkdir -p "$a/$(dirname "$f")"
      git show "$base_sha:$f" >"$a/$f"
      (cd "$WORK" && diff -u "a/$f" "b/$f") || true
    done
    echo
    echo "================ seção do CHANGELOG.md que seria inserida ================"
    cat "$WORK_SECTION"
    echo
    echo "================ comandos que rodariam ================"
    [ "$HOTFIX" -eq 1 ] || echo "  git switch -c $branch $dev_ref"
    echo "  # (bump + CHANGELOG acima)"
    echo "  git add $(echo "$files" | tr '\n' ' ')"
    echo "  git commit -m 'chore(release): $tag'"
    echo "  git push -u $REMOTE $branch"
    echo "  $GH pr create --repo $REPO_SLUG --base $MAIN_BRANCH --head $branch --title '$title' --body-file <corpo>"
    echo
    info "dry-run concluído: nada foi escrito ($CHANGELOG_LISTED entradas no CHANGELOG, $FILTERED filtradas)"
    return 0
  fi

  # shellcheck disable=SC2086
  git add -- $files
  local msg="chore(release): $tag"
  [ -n "$TICKET" ] && msg="$msg

$TICKET"
  git commit --quiet -m "$msg"
  git push -u "$REMOTE" "$branch"
  "$GH" pr create --repo "$REPO_SLUG" --base "$MAIN_BRANCH" --head "$branch" --title "$title" --body-file "$body"
  info "PR de release aberto. Depois do merge: tool/release.sh tag $version"
}

# ---------------------------------------------------------------- tag

find_release_commit() {
  local version="$1" head sha
  if [ -n "$COMMIT_OVERRIDE" ]; then
    git rev-parse -q --verify "$COMMIT_OVERRIDE^{commit}" || die "--commit $COMMIT_OVERRIDE não resolve"
    return
  fi
  for head in "release/v$version" "hotfix/v$version"; do
    sha="$("$GH" pr list --repo "$REPO_SLUG" --head "$head" --base "$MAIN_BRANCH" --state merged --json mergeCommit --jq '.[0].mergeCommit.oid // empty' 2>/dev/null || true)"
    if [ -n "$sha" ]; then echo "$sha"; return; fi
  done
  die "nenhum PR mergeado de release/v$version ou hotfix/v$version em $MAIN_BRANCH; passe --commit <sha> se o merge foi por outro caminho"
}

# The tag goes on the merge commit that brought the release into <main-ref>:
# on main's own (first-parent) line, a merge, and the first commit of that
# line with <version> (its first parent has another one). Any other ancestor
# of main that carries the version (the bump commit of the release branch, a
# later commit on main) is refused.
assert_release_merge_commit() {
  local commit="$1" main_ref="$2" version="$3" short fp="$WORK/first-parent.txt" n_parents parent_v
  short="$(git rev-parse --short "$commit")"
  # Via file, not a pipe into grep -q: under pipefail an early-exiting grep
  # gives rev-list a SIGPIPE on long histories and the check fails at random.
  git rev-list --first-parent "$main_ref" >"$fp"
  grep -qxF "$commit" "$fp" \
    || die "$short não está na linha first-parent de $main_ref (é commit de branch, não o merge na $MAIN_BRANCH); use o merge commit do PR de release"
  n_parents="$(git rev-list --parents -n1 "$commit" | awk '{print NF-1}')"
  [ "$n_parents" -ge 2 ] \
    || die "$short não é merge commit; a tag vai no merge commit do PR de release (merge com \"Create a merge commit\")"
  parent_v="$(workspace_version_at "$commit^1" 2>/dev/null || true)"
  [ "$parent_v" != "$version" ] \
    || die "$short não é o merge que trouxe $version para $main_ref (o primeiro pai já tem $version); use o merge commit do PR de release"
}

cmd_tag() {
  local version="$1" tag="v$1"
  validate_semver "$version"
  fetch_remote
  local main_ref="$REMOTE/$MAIN_BRANCH" commit
  git rev-parse -q --verify "$main_ref^{commit}" >/dev/null || die "$main_ref não existe"
  commit="$(find_release_commit "$version")"
  git cat-file -e "$commit^{commit}" 2>/dev/null || die "commit $commit não está no repo local (fetch?)"
  git merge-base --is-ancestor "$commit" "$main_ref" || die "$commit não está em $main_ref"

  # An existing tag is never moved: checked before anything about the commit.
  local lt rt
  lt="$(local_tag_commit "$tag")"
  rt="$(remote_tag_commit "$tag")"
  if [ -n "$lt" ] && [ "$lt" != "$commit" ]; then die "a tag $tag já existe localmente em $lt (esperado $commit); tag nunca é movida"; fi
  if [ -n "$rt" ] && [ "$rt" != "$commit" ]; then die "a tag $tag já existe em $REMOTE em $rt (esperado $commit); tag nunca é movida"; fi

  local at short
  short="$(git rev-parse --short "$commit")"
  at="$(workspace_version_at "$commit")"
  [ "$at" = "$version" ] || die "$main_ref em $short tem a versão $at nos pubspecs, não $version"
  assert_literals_match "$commit" "$version"
  local notes="$WORK/notes.md"
  git show "$commit:CHANGELOG.md" 2>/dev/null | extract_changelog_section "$version" >"$notes" || true
  grep -q . "$notes" || die "CHANGELOG.md em $short não tem a seção $version"
  assert_release_merge_commit "$commit" "$main_ref" "$version"

  info "release commit: $commit ($main_ref)"
  if [ -n "$lt" ]; then
    info "tag $tag já existe localmente no commit certo"
  else
    run_or_print git tag -a "$tag" -m "comon_opentelemetry $tag" "$commit"
  fi
  if [ -n "$rt" ]; then
    info "tag $tag já está em $REMOTE no commit certo"
  else
    run_or_print git push "$REMOTE" "refs/tags/$tag"
  fi
  if "$GH" release view "$tag" --repo "$REPO_SLUG" >/dev/null 2>&1; then
    info "GitHub Release $tag já existe"
  else
    run_or_print "$GH" release create "$tag" --repo "$REPO_SLUG" --verify-tag --title "$tag" --notes-file "$notes"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "================ notas da release ================"
    cat "$notes"
    info "dry-run concluído: nada foi escrito"
  else
    info "próximo passo: tool/release.sh back-merge $version; depois tool/release.sh pin-snippet $version"
  fi
}

# ---------------------------------------------------------------- back-merge

cmd_back_merge() {
  local version="$1" tag="v$1"
  validate_semver "$version"
  fetch_remote
  local commit dev_ref="$REMOTE/$DEV_BRANCH"
  commit="$(local_tag_commit "$tag")"
  [ -n "$commit" ] || die "a tag $tag não existe; rode tool/release.sh tag $version antes"
  if git merge-base --is-ancestor "$commit" "$dev_ref"; then
    info "$dev_ref já contém $tag — nada a fazer"
    return 0
  fi
  local open_pr
  open_pr="$("$GH" pr list --repo "$REPO_SLUG" --head "$MAIN_BRANCH" --base "$DEV_BRANCH" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  if [ -n "$open_pr" ]; then
    info "back-merge já aberto: $open_pr (merge com \"Create a merge commit\")"
    return 0
  fi
  local title="Back-merge $tag ($MAIN_BRANCH -> $DEV_BRANCH)"
  [ -n "$TICKET" ] && title="[$TICKET] $title"
  local body="$WORK/back-merge.md"
  {
    echo "Traz \`$MAIN_BRANCH\` (release \`$tag\`: bump de versão + CHANGELOG) de volta para \`$DEV_BRANCH\`."
    echo
    echo "**Merge com \"Create a merge commit\"** (não squash/rebase): o próximo \`prepare\` exige que \`$tag\` seja ancestral de \`$DEV_BRANCH\`."
  } >"$body"
  run_or_print "$GH" pr create --repo "$REPO_SLUG" --base "$DEV_BRANCH" --head "$MAIN_BRANCH" --title "$title" --body-file "$body"
  [ "$DRY_RUN" -eq 1 ] && info "dry-run concluído: nada foi escrito"
  return 0
}

# ---------------------------------------------------------------- pin-snippet

cmd_pin_snippet() {
  local version="$1" tag="v$1"
  validate_semver "$version"
  local lt rt sha
  lt="$(local_tag_commit "$tag")"
  rt="$(remote_tag_commit "$tag")"
  if [ -n "$lt" ] && [ -n "$rt" ] && [ "$lt" != "$rt" ]; then
    die "a tag $tag aponta para commits diferentes local ($lt) e em $REMOTE ($rt)"
  fi
  sha="${rt:-$lt}"
  [ -n "$sha" ] || die "a tag $tag não existe (local nem em $REMOTE); rode tool/release.sh tag $version antes"
  [ -n "$rt" ] || warn "a tag $tag só existe localmente; o app não vai resolver até ela estar em $REMOTE"
  git cat-file -e "$sha^{commit}" 2>/dev/null || die "commit $sha da tag não está no repo local; rode git fetch --tags $REMOTE"
  echo "  # comon_opentelemetry $tag. O ref é o SHA completo do commit da tag, não"
  echo "  # o nome da tag: os pacotes-folha dependem do comon_otel por path, que o"
  echo "  # pub resolve para o SHA completo; pinar pelo nome da tag ou por SHA curto"
  echo "  # quebra o version solving. Ver docs/RELEASING.md no fork."
  local pkg
  for pkg in $(packages_at "$sha"); do
    echo "  $(basename "$pkg"):"
    echo "    git:"
    echo "      url: $GIT_URL"
    echo "      ref: $sha # $tag"
    echo "      path: $pkg"
  done
}

# ---------------------------------------------------------------- main

main() {
  [ $# -ge 2 ] || usage
  local cmd="$1" version="$2"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --hotfix) HOTFIX=1 ;;
      --with-integration) WITH_INTEGRATION=1 ;;
      --skip-gates) SKIP_GATES=1 ;;
      --since) [ $# -ge 2 ] || usage; SINCE="$2"; shift ;;
      --ticket) [ $# -ge 2 ] || usage; TICKET="$2"; shift ;;
      --commit) [ $# -ge 2 ] || usage; COMMIT_OVERRIDE="$2"; shift ;;
      -h|--help) usage ;;
      *) echo "flag desconhecida: $1" >&2; usage ;;
    esac
    shift
  done
  if [ "$SKIP_GATES" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    die "--skip-gates só é aceito com --dry-run"
  fi
  command -v git >/dev/null || die "git não encontrado"
  command -v jq >/dev/null || die "jq não encontrado"
  cd "$(git rev-parse --show-toplevel 2>/dev/null)" || die "rode dentro do repositório"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX")"

  case "$cmd" in
    prepare) cmd_prepare "$version" ;;
    tag) cmd_tag "$version" ;;
    back-merge) cmd_back_merge "$version" ;;
    pin-snippet) cmd_pin_snippet "$version" ;;
    *) usage ;;
  esac
}

main "$@"
