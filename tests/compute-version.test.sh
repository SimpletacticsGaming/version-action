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

# Builds "$WORK/<name>/src" with one commit per supplied committer date, then
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

  local i=0 date
  for date in "$@"; do
    i=$((i + 1))
    printf 'change %s\n' "$i" > "$root/src/file-$i.txt"
    git -C "$root/src" add .
    GIT_COMMITTER_DATE="$date" GIT_AUTHOR_DATE="$date" \
      git -C "$root/src" commit -q -m "commit $i"
  done

  git clone -q "$root/src" "$root/clone"
  git -C "$root/clone" config core.hooksPath "$HOOKS"
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
        GITHUB_REF_NAME=main \
        GITHUB_SHA="$(git rev-parse HEAD)" \
        "$@" bash "$SCRIPT"
  ) >"$stdout_file" 2>"$stderr_file"
  status=$?
  out="$(cat "$stdout_file")"
  err="$(cat "$stderr_file")"
}

# Reads one key=value pair out of $out.
field() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }

write_pr_event() {
  local path="$1" sha="$2"
  printf '{"pull_request":{"number":42,"head":{"sha":"%s"}}}\n' "$sha" > "$path"
}

# --- cases ------------------------------------------------------------------

describe "strips leading zeros from month and day"
repo="$(make_repo zeros "2026-01-05T04:05:06+00:00")"
run "$repo"
assert_eq 0 "$status" "exit code"
assert_eq "2026.1.5040506" "$(field version)" "version"
assert_eq "false" "$(field is_prerelease)" "is_prerelease"
assert_eq "2026-01-05T04:05:06Z" "$(field commit_date)" "commit_date"

describe "keeps hhmmss zero-padded to six digits"
repo="$(make_repo padded "2026-03-01T00:00:05+00:00")"
run "$repo"
assert_eq "2026.3.1000005" "$(field version)" "version"

describe "end of day and end of year"
repo="$(make_repo edges "2026-12-31T23:59:59+00:00")"
run "$repo"
assert_eq "2026.12.31235959" "$(field version)" "version"

describe "converts a non-UTC committer date to UTC"
# 2026-01-01T00:30:00+02:00 is 2025-12-31T22:30:00 UTC.
repo="$(make_repo tzshift "2026-01-01T00:30:00+02:00")"
run "$repo"
assert_eq "2025.12.31223000" "$(field version)" "version"

describe "day 9 sorts below day 10 under sort -V"
repo="$(make_repo day9 "2026-10-09T23:59:59+00:00")"
run "$repo"; v9="$(field version)"
repo="$(make_repo day10 "2026-10-10T00:00:00+00:00")"
run "$repo"; v10="$(field version)"
assert_eq "2026.10.9235959" "$v9" "day 9 version"
assert_eq "2026.10.10000000" "$v10" "day 10 version"
assert_eq "$v10" "$(printf '%s\n%s\n' "$v9" "$v10" | sort -V | tail -n 1)" "sort -V picks day 10"
# The regression plain `sort` would introduce, asserted explicitly.
assert_eq "$v9" "$(printf '%s\n%s\n' "$v9" "$v10" | sort | tail -n 1)" "plain sort is wrong (documented)"

describe "feature branch gets a -g<sha> prerelease suffix"
repo="$(make_repo feature "2026-10-29T14:35:07+00:00")"
run "$repo" GITHUB_REF_NAME=feat/some-work
assert_eq "false" "$(field is_protected)" "is_protected"
assert_eq "true" "$(field is_prerelease)" "is_prerelease"
assert_match '^2026\.10\.29143507-g[0-9a-f]{7}$' "$(field version)" "version"
# The 'g' prefix is what keeps an all-digit short sha a valid semver
# prerelease identifier, so the suffix must never be bare digits.
assert_match '-g[0-9a-f]+$' "$(field version)" "prerelease identifier is never all-numeric"

describe "sha_length controls the suffix length"
repo="$(make_repo shalen "2026-10-29T14:35:07+00:00")"
run "$repo" GITHUB_REF_NAME=feat/x INPUT_SHA_LENGTH=12
assert_match '^2026\.10\.29143507-g[0-9a-f]{12}$' "$(field version)" "version"
assert_eq 12 "$(printf '%s' "$(field short_sha)" | wc -c | tr -d ' ')" "short_sha length"

describe "glob patterns match protected branches"
repo="$(make_repo globs "2026-10-29T14:35:07+00:00")"
run "$repo" GITHUB_REF_NAME=release/1.x INPUT_PROTECTED_BRANCHES='main
release/*'
assert_eq "true" "$(field is_protected)" "is_protected"
assert_eq "2026.10.29143507" "$(field version)" "version"

describe "a pull request from a protected branch is still a prerelease"
repo="$(make_repo prprotected "2026-10-29T14:35:07+00:00")"
head_sha="$(git -C "$repo" rev-parse HEAD)"
write_pr_event "$WORK/pr-protected.json" "$head_sha"
run "$repo" GITHUB_EVENT_NAME=pull_request GITHUB_HEAD_REF=main \
    GITHUB_EVENT_PATH="$WORK/pr-protected.json"
assert_eq "true" "$(field is_protected)" "is_protected"
assert_eq "true" "$(field is_prerelease)" "is_prerelease"

describe "a pull request uses head.sha, not the merge GITHUB_SHA"
# Commit 1 stands in for the PR head, commit 2 for the ephemeral merge commit
# whose committer date would otherwise leak into the version.
repo="$(make_repo prhead "2026-02-03T01:02:03+00:00" "2026-07-08T09:10:11+00:00")"
head_sha="$(git -C "$repo" rev-parse HEAD~1)"
merge_sha="$(git -C "$repo" rev-parse HEAD)"
write_pr_event "$WORK/pr-head.json" "$head_sha"
run "$repo" GITHUB_EVENT_NAME=pull_request GITHUB_HEAD_REF=feat/x \
    GITHUB_SHA="$merge_sha" GITHUB_EVENT_PATH="$WORK/pr-head.json"
assert_eq "$head_sha" "$(field commit_sha)" "commit_sha"
assert_match '^2026\.2\.3010203-g' "$(field version)" "version comes from the head commit"

describe "fetches a PR head commit missing from a shallow clone"
repo="$(make_repo shallow "2026-02-03T01:02:03+00:00" "2026-07-08T09:10:11+00:00")"
src="$(dirname "$repo")/src"
head_sha="$(git -C "$src" rev-parse HEAD~1)"
shallow="$(dirname "$repo")/shallow"
git clone -q --depth=1 "file://$src" "$shallow"
git -C "$shallow" config core.hooksPath "$HOOKS"
if git -C "$shallow" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
  bad "fixture invalid: shallow clone already contains $head_sha"
else
  ok "shallow clone does not contain the head commit"
  write_pr_event "$WORK/pr-shallow.json" "$head_sha"
  run "$shallow" GITHUB_EVENT_NAME=pull_request GITHUB_HEAD_REF=feat/x \
      GITHUB_EVENT_PATH="$WORK/pr-shallow.json"
  assert_eq 0 "$status" "exit code"
  assert_eq "$head_sha" "$(field commit_sha)" "commit_sha after fetch"
  assert_match '^2026\.2\.3010203-g' "$(field version)" "version"
fi

describe "an existing tag at the same commit is idempotent"
repo="$(make_repo idempotent "2026-10-29T14:35:07+00:00")"
src="$(dirname "$repo")/src"
git -C "$src" tag -a v2026.10.29143507 -m "release"
run "$repo"
assert_eq 0 "$status" "exit code"
assert_eq "true" "$(field tag_exists)" "tag_exists"
assert_eq "2026.10.29143507" "$(field version)" "version"

describe "an existing tag at a different commit is a hard failure"
repo="$(make_repo collision "2026-10-29T14:35:07+00:00" "2026-11-30T01:02:03+00:00")"
src="$(dirname "$repo")/src"
# Tag the newer commit with the version the older commit will compute.
git -C "$src" tag -a v2026.10.29143507 -m "squatter" HEAD
git -C "$repo" fetch -q --tags
run "$repo" GITHUB_SHA="$(git -C "$repo" rev-parse HEAD~1)"
assert_eq 1 "$status" "exit code"
assert_contains "Version collision" "$err" "stderr"

describe "a lightweight tag is detected too"
repo="$(make_repo lightweight "2026-10-29T14:35:07+00:00")"
src="$(dirname "$repo")/src"
git -C "$src" tag v2026.10.29143507
run "$repo"
assert_eq 0 "$status" "exit code"
assert_eq "true" "$(field tag_exists)" "tag_exists"

describe "a version older than the latest release warns by default"
repo="$(make_repo monotonic "2026-10-29T14:35:07+00:00")"
src="$(dirname "$repo")/src"
git -C "$src" tag -a v2026.12.1000000 -m "newer release"
run "$repo"
assert_eq 0 "$status" "exit code"
assert_contains "::warning::" "$err" "stderr"
assert_contains "older than the latest released version" "$err" "stderr"

describe "non_monotonic=fail turns that warning into an error"
run "$repo" INPUT_NON_MONOTONIC=fail
assert_eq 1 "$status" "exit code"
assert_contains "::error::" "$err" "stderr"

describe "non_monotonic=ignore stays silent"
run "$repo" INPUT_NON_MONOTONIC=ignore
assert_eq 0 "$status" "exit code"
if [[ "$err" == *"older than the latest"* ]]; then
  bad "stderr should not mention monotonicity: $err"
else
  ok "stderr is quiet about monotonicity"
fi

describe "monotonicity ignores tags that are not CalVer"
repo="$(make_repo mixedtags "2026-10-29T14:35:07+00:00")"
src="$(dirname "$repo")/src"
git -C "$src" tag -a v9.9.9 -m "old semver scheme"
git -C "$src" tag -a not-a-version -m "noise"
run "$repo"
assert_eq 0 "$status" "exit code"
if [[ "$err" == *"older than the latest"* ]]; then
  bad "non-CalVer tags should be skipped: $err"
else
  ok "non-CalVer tags are skipped"
fi

describe "tag_prefix is configurable"
repo="$(make_repo prefix "2026-10-29T14:35:07+00:00")"
run "$repo" INPUT_TAG_PREFIX=""
assert_eq "2026.10.29143507" "$(field tag)" "tag without prefix"
run "$repo" INPUT_TAG_PREFIX="release-"
assert_eq "release-2026.10.29143507" "$(field tag)" "tag with custom prefix"

describe "an explicit version override wins"
repo="$(make_repo override "2026-10-29T14:35:07+00:00")"
run "$repo" INPUT_VERSION=1.2.3
assert_eq "1.2.3" "$(field version)" "version"
assert_eq "v1.2.3" "$(field tag)" "tag"
assert_eq "false" "$(field is_prerelease)" "is_prerelease"
run "$repo" INPUT_VERSION=1.2.3-rc.1
assert_eq "true" "$(field is_prerelease)" "is_prerelease for a prerelease override"

describe "invalid configuration is rejected"
repo="$(make_repo badconfig "2026-10-29T14:35:07+00:00")"
run "$repo" INPUT_SHA_LENGTH=abc
assert_eq 1 "$status" "sha_length=abc exit code"
assert_contains "sha_length must be a number" "$err" "stderr"
run "$repo" INPUT_SHA_LENGTH=2
assert_eq 1 "$status" "sha_length=2 exit code"
run "$repo" INPUT_NON_MONOTONIC=maybe
assert_eq 1 "$status" "non_monotonic=maybe exit code"
assert_contains "non_monotonic must be one of" "$err" "stderr"

describe "every computed version is valid semver"
repo="$(make_repo semver "2026-01-05T04:05:06+00:00")"
semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?$'
run "$repo"
assert_match "$semver_re" "$(field version)" "release version"
run "$repo" GITHUB_REF_NAME=feat/x
assert_match "$semver_re" "$(field version)" "prerelease version"

describe "the third component stays below Int32"
# Day 31 at 23:59:59 is the largest possible value: 31235959 < 2147483647.
repo="$(make_repo int32 "2026-12-31T23:59:59+00:00")"
run "$repo"
patch="$(field version)"; patch="${patch##*.}"
if (( patch < 2147483647 )); then
  ok "patch $patch fits in Int32"
else
  bad "patch $patch exceeds Int32"
fi

# --- summary ----------------------------------------------------------------

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
