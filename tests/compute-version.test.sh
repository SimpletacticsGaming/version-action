#!/usr/bin/env bash
#
# Tests for scripts/compute-version.sh. Plain bash, no test framework, no
# network: each case builds a throwaway repository with pinned committer dates
# and clones it over the file protocol to stand in for `origin`.
#
#   bash tests/compute-version.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/compute-version.sh"
WORK="$(mktemp -d)"
# Neutralise any user- or system-wide hooks (e.g. commit-msg linters) so
# fixture commits are never rejected.
HOOKS="$WORK/_nohooks"
mkdir -p "$HOOKS"

trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

# --- harness ----------------------------------------------------------------

describe() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ok()   { passed=$((passed + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { failed=$((failed + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }

assert_eq() {
  local expected="$1" actual="$2" what="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$what = $actual"
  else
    bad "$what: expected '$expected', got '$actual'"
  fi
}

assert_match() {
  local pattern="$1" actual="$2" what="$3"
  if [[ "$actual" =~ $pattern ]]; then
    ok "$what matches $pattern ($actual)"
  else
    bad "$what: '$actual' does not match $pattern"
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" what="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$what mentions '$needle'"
  else
    bad "$what: expected to mention '$needle', got: $haystack"
  fi
}

# Builds "$WORK/<name>/src" with one commit per supplied commit message, then
# clones it to "$WORK/<name>/clone" and echoes the clone path.
make_repo() {
  local name="$1"; shift
  local root="$WORK/$name"
  rm -rf "$root"
  mkdir -p "$root"
  git init -q -b main "$root/src"
  git -C "$root/src" config core.hooksPath "$HOOKS"
  git -C "$root/src" config user.email test@example.com
  git -C "$root/src" config user.name "Test"
  # Lets the fetch-by-sha path be exercised over the file protocol, the way
  # GitHub serves it.
  git -C "$root/src" config uploadpack.allowAnySHA1InWant true

  local i=0 message
  for message in "$@"; do
    i=$((i + 1))
    printf 'change %s\n' "$i" > "$root/src/file-$i.txt"
    git -C "$root/src" add .
    git -C "$root/src" commit -q -m "$message"
  done

  git clone -q "$root/src" "$root/clone"
  git -C "$root/clone" config core.hooksPath "$HOOKS"
  # Cases that add commits do so in the clone, which inherits nothing from src.
  # Without an identity here those commits fail on a runner that has no global
  # one configured, and the assertions then read a stale history.
  git -C "$root/clone" config user.email test@example.com
  git -C "$root/clone" config user.name "Test"
  printf '%s\n' "$root/clone"
}

# Runs the script inside $1 with the remaining arguments as VAR=value env
# overrides. Captures stdout in $out, stderr in $err, exit code in $status.
run() {
  local repo="$1"; shift
  local stdout_file="$WORK/_stdout" stderr_file="$WORK/_stderr"
  (
    cd "$repo" || exit 1
    env -u GITHUB_HEAD_REF -u GITHUB_EVENT_PATH -u INPUT_VERSION \
        GITHUB_EVENT_NAME=push \
        GITHUB_REF_NAME="$(git rev-parse --abbrev-ref HEAD)" \
        GITHUB_SHA="$(git rev-parse HEAD)" \
        SEMVER_CMD="bash $STUB" \
        "$@" bash "$SCRIPT"
  ) >"$stdout_file" 2>"$stderr_file"
  status=$?
  out="$(cat "$stdout_file")"
  err="$(cat "$stderr_file")"
}

# Reads one key=value pair out of $out.
field() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

# Stands in for `node next-semver.mjs`. The real thing is exercised by the
# self-test job in CI; here it is stubbed so the suite stays offline and fast.
# STUB_VERSION controls what it reports; unset means "nothing to release".
STUB="$WORK/_next-semver-stub.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
if [[ -n "${STUB_VERSION:-}" ]]; then
  printf '{"version":"%s","type":"%s","lastVersion":null}' \
    "$STUB_VERSION" "${STUB_TYPE:-minor}" > "$SR_OUT"
else
  printf '{"version":null,"type":null,"lastVersion":null}' > "$SR_OUT"
fi
STUBEOF
chmod +x "$STUB"

# --- cases ------------------------------------------------------------------

describe "dev builds append -g<sha> to the version semantic-release reports"
repo="$(make_repo dev "feat: one")"
run "$repo" STUB_VERSION=1.4.0
assert_eq "1.4.0" "$(field base_version)" "base_version"
assert_match '^1\.4\.0-g[0-9a-f]{7}$' "$(field version)" "version"
assert_eq "true" "$(field is_prerelease)" "is_prerelease"
assert_eq "true" "$(field has_release)" "has_release"

describe "the -g prefix keeps an all-digit short sha valid semver"
# Without it, a sha like 0123456 is an invalid numeric identifier with a leading zero.
run "$repo" STUB_VERSION=1.4.0 INPUT_SHA_LENGTH=8
assert_match '^1\.4\.0-g[0-9a-f]{8}$' "$(field version)" "version with sha_length 8"

describe "sha_length controls the suffix length"
run "$repo" STUB_VERSION=1.4.0 INPUT_SHA_LENGTH=12
short="$(field short_sha)"
assert_eq "12" "${#short}" "short_sha length"

describe "no releasable commit still yields a buildable version"
repo="$(make_repo norelease "feat: one")"
git -C "$repo" tag v1.4.0
run "$repo"
assert_eq "false" "$(field has_release)" "has_release"
assert_eq "1.4.1" "$(field base_version)" "base_version falls back to a patch bump"
assert_match '^1\.4\.1-g[0-9a-f]{7}$' "$(field version)" "version"

describe "a release branch derives its base from the branch name, not commits"
repo="$(make_repo relbranch "feat: one")"
git -C "$repo" checkout -q -b release/1.4
# STUB_VERSION is deliberately wrong: the release path must not consult it.
run "$repo" INPUT_CHANNEL=rc STUB_VERSION=9.9.9
assert_eq "1.4.0" "$(field base_version)" "base_version"
assert_eq "1.4.0-rc.1" "$(field version)" "version"
assert_eq "1" "$(field rc_number)" "rc_number"

describe "rc numbers increment within a base version"
git -C "$repo" tag v1.4.0-rc.1
printf 'more\n' > "$repo/more.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "fix: two"
run "$repo" INPUT_CHANNEL=rc
assert_eq "1.4.0-rc.2" "$(field version)" "version"
assert_eq "false" "$(field tag_exists)" "tag_exists"

describe "re-cutting an rc on the same commit reuses it"
git -C "$repo" tag v1.4.0-rc.2
run "$repo" INPUT_CHANNEL=rc
assert_eq "1.4.0-rc.2" "$(field version)" "version"
assert_eq "true" "$(field tag_exists)" "tag_exists"

describe "after a final release the series moves to the next patch"
git -C "$repo" tag v1.4.0
printf 'hotfix\n' > "$repo/hotfix.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "fix: three"
run "$repo" INPUT_CHANNEL=rc
assert_eq "1.4.1" "$(field base_version)" "base_version"
assert_eq "1.4.1-rc.1" "$(field version)" "version"

describe "dev builds on a release branch use the same base, with -g<sha>"
run "$repo" INPUT_CHANNEL=dev STUB_VERSION=9.9.9
assert_eq "1.4.1" "$(field base_version)" "base_version ignores semantic-release"
assert_match '^1\.4\.1-g[0-9a-f]{7}$' "$(field version)" "version"

describe "tags on unrelated branches do not raise the base"
repo="$(make_repo unrelated "feat: one")"
git -C "$repo" checkout -q -b other
printf 'o\n' > "$repo/o.txt"; git -C "$repo" add . && git -C "$repo" commit -q -m "feat: other"
git -C "$repo" tag v1.4.7
git -C "$repo" checkout -q -b release/1.4 main
run "$repo" INPUT_CHANNEL=rc
assert_eq "1.4.0" "$(field base_version)" "base_version ignores v1.4.7 on 'other'"

describe "promotion strips -rc.N and verifies the tag exists"
repo="$(make_repo promote "feat: one")"
git -C "$repo" checkout -q -b release/2.0
git -C "$repo" tag v2.0.0-rc.3
run "$repo" INPUT_CHANNEL=release INPUT_PROMOTE_FROM=v2.0.0-rc.3
assert_eq "2.0.0" "$(field version)" "version"
assert_eq "3" "$(field rc_number)" "rc_number"
assert_eq "false" "$(field is_prerelease)" "is_prerelease"
assert_eq "false" "$(field tag_exists)" "tag_exists"

describe "promoting an already-promoted rc is a no-op, not a failure"
git -C "$repo" tag v2.0.0
run "$repo" INPUT_CHANNEL=release INPUT_PROMOTE_FROM=v2.0.0-rc.3
assert_eq "0" "$status" "exit status"
assert_eq "true" "$(field tag_exists)" "tag_exists"

describe "promoting a tag that does not exist fails loudly"
run "$repo" INPUT_CHANNEL=release INPUT_PROMOTE_FROM=v2.0.0-rc.9
assert_eq "1" "$status" "exit status"
assert_contains "does not exist" "$err" "error"

describe "promotion works on a detached HEAD"
# promote.yml checks the rc tag out directly, so HEAD is detached and the branch
# name is the tag. Nothing may fall through to commit analysis on that path.
repo="$(make_repo detached "feat: one")"
git -C "$repo" checkout -q -b release/2.0
git -C "$repo" tag v2.0.0-rc.1
git -C "$repo" checkout -q v2.0.0-rc.1
run "$repo" INPUT_CHANNEL=release INPUT_PROMOTE_FROM=v2.0.0-rc.1 GITHUB_REF_NAME=v2.0.0-rc.1
assert_eq "0" "$status" "exit status"
assert_eq "2.0.0" "$(field version)" "version"
assert_eq "false" "$(field is_prerelease)" "is_prerelease"

describe "a release branch owns its line, so trunk skips past it"
repo="$(make_repo floor "feat: one")"
git -C "$repo" branch release/1.4
git -C "$repo" push -q origin release/1.4
run "$repo" STUB_VERSION=1.4.0
assert_eq "1.5.0" "$(field base_version)" "base_version raised above the cut series"

describe "the floor never lowers a version that is already higher"
run "$repo" STUB_VERSION=2.0.0
assert_eq "2.0.0" "$(field base_version)" "base_version"

describe "a malformed release branch name is rejected"
repo="$(make_repo badbranch "feat: one")"
git -C "$repo" checkout -q -b release/nonsense
run "$repo" INPUT_CHANNEL=rc
assert_eq "1" "$status" "exit status"
assert_contains "release/<major>.<minor>" "$err" "error"

describe "rc outside a release branch is rejected"
repo="$(make_repo rcoffbranch "feat: one")"
run "$repo" INPUT_CHANNEL=rc
assert_eq "1" "$status" "exit status"
assert_contains "must run on a release/" "$err" "error"

describe "tag_prefix is configurable"
repo="$(make_repo prefix "feat: one")"
git -C "$repo" checkout -q -b release/3.1
git -C "$repo" tag 3.1.0-rc.1
printf 'next\n' > "$repo/next.txt"
git -C "$repo" add . && git -C "$repo" commit -q -m "fix: next"
run "$repo" INPUT_CHANNEL=rc INPUT_TAG_PREFIX=
assert_eq "3.1.0-rc.2" "$(field version)" "version"
assert_eq "3.1.0-rc.2" "$(field tag)" "tag has no prefix"

describe "an explicit version override wins"
repo="$(make_repo override "feat: one")"
run "$repo" STUB_VERSION=1.4.0 INPUT_VERSION=9.9.9
assert_eq "9.9.9" "$(field version)" "version"
assert_eq "false" "$(field is_prerelease)" "is_prerelease"

describe "invalid configuration is rejected"
run "$repo" INPUT_CHANNEL=nonsense
assert_eq "1" "$status" "exit status for a bad channel"
run "$repo" STUB_VERSION=1.4.0 INPUT_SHA_LENGTH=2
assert_eq "1" "$status" "exit status for a short sha_length"

describe "every computed version is valid semver"
repo="$(make_repo semver "feat: one")"
run "$repo" STUB_VERSION=1.4.0
assert_match '^[0-9]+\.[0-9]+\.[0-9]+-g[0-9a-f]+$' "$(field version)" "dev version"
git -C "$repo" checkout -q -b release/1.4
run "$repo" INPUT_CHANNEL=rc
assert_match '^[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' "$(field version)" "rc version"

# --- summary ----------------------------------------------------------------

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
