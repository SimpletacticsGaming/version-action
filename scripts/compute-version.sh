#!/usr/bin/env bash
#
# Computes a CalVer version from a commit's committer date in UTC.
#
#   yyyy.m.dhhmmss              on protected branches   (2026.10.29143507)
#   yyyy.m.dhhmmss-g<shortsha>  everywhere else         (2026.10.29143507-g1a2b3c4)
#
# Month and day carry no leading zeros (semver forbids them in numeric
# identifiers); hhmmss stays zero-padded to exactly six digits, so the third
# component is unambiguous and sorts monotonically.
#
# Configured through INPUT_* environment variables, reads the GitHub Actions
# context from GITHUB_*, and writes `key=value` lines to stdout. All
# diagnostics go to stderr so stdout can be appended to $GITHUB_OUTPUT.

set -euo pipefail

EVENT_NAME="${GITHUB_EVENT_NAME:-push}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
PROTECTED_BRANCHES="${INPUT_PROTECTED_BRANCHES:-main,master}"
# `-` rather than `:-` so an explicitly empty tag_prefix is honoured.
TAG_PREFIX="${INPUT_TAG_PREFIX-v}"
SHA_LENGTH="${INPUT_SHA_LENGTH:-7}"
NON_MONOTONIC="${INPUT_NON_MONOTONIC:-warn}"
VERSION_OVERRIDE="${INPUT_VERSION:-}"
REMOTE="${INPUT_REMOTE:-origin}"

# Shape of a released version: 4-digit year, month and day+time without a
# leading zero. Guards against format drift in the steps below.
CALVER_RE='^[0-9]{4}\.[1-9][0-9]?\.[1-9][0-9]{6,7}$'

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# --- validate configuration -------------------------------------------------

[[ "$SHA_LENGTH" =~ ^[0-9]+$ ]] || die "sha_length must be a number, got '$SHA_LENGTH'."
(( SHA_LENGTH >= 4 && SHA_LENGTH <= 40 )) || die "sha_length must be between 4 and 40, got '$SHA_LENGTH'."

case "$NON_MONOTONIC" in
  warn|fail|ignore) ;;
  *) die "non_monotonic must be one of warn, fail, ignore; got '$NON_MONOTONIC'." ;;
esac

# --- resolve the commit to version ------------------------------------------

# On pull_request events GITHUB_SHA is the ephemeral refs/pull/N/merge commit,
# whose committer date is the moment the merge ref was built and therefore
# changes on every re-run. The PR head commit is the only stable choice.
sha=""
if [[ "$EVENT_NAME" == pull_request* ]]; then
  [[ -n "$EVENT_PATH" && -f "$EVENT_PATH" ]] \
    || die "Event is '$EVENT_NAME' but GITHUB_EVENT_PATH ('$EVENT_PATH') is not readable."
  command -v jq >/dev/null 2>&1 || die "jq is required to read the pull_request event payload."
  sha="$(jq -r '.pull_request.head.sha // empty' "$EVENT_PATH")"
  [[ -n "$sha" ]] || die "Could not read .pull_request.head.sha from $EVENT_PATH."
fi
[[ -n "$sha" ]] || sha="${GITHUB_SHA:-HEAD}"

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "Not inside a git repository. Run actions/checkout before this action."

# A shallow clone (fetch-depth: 1) of a merge ref does not contain the PR head
# commit. GitHub serves fetch-by-sha, so pull in just that one commit.
if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
  log "Commit $sha is not present locally (shallow clone?); fetching it from $REMOTE."
  git fetch --no-tags --depth=1 "$REMOTE" "$sha" >/dev/null 2>&1 \
    || git fetch --no-tags "$REMOTE" "$sha" >/dev/null 2>&1 \
    || die "Unable to fetch commit $sha from '$REMOTE'. Use fetch-depth: 0 in actions/checkout."
fi

commit_sha="$(git rev-parse "${sha}^{commit}")"
# Plain truncation rather than `rev-parse --short`, whose length varies with
# repository size and core.abbrev and would make the version non-deterministic.
short_sha="${commit_sha:0:SHA_LENGTH}"
commit_date="$(TZ=UTC git show -s --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' "$commit_sha")"

# --- build the version string -----------------------------------------------

# `format-local` plus TZ=UTC is what yields UTC. A plain `--date=format:` would
# render the committer's original timezone instead.
read -r c_year c_month c_day c_time <<<"$(
  TZ=UTC git show -s --format=%cd --date=format-local:'%Y %m %d %H%M%S' "$commit_sha"
)"
# 10# forces base-10 so 08/09 are not read as invalid octal.
calver="${c_year}.$((10#$c_month)).$((10#$c_day))${c_time}"

[[ "$calver" =~ $CALVER_RE ]] \
  || die "Computed version '$calver' does not match the expected yyyy.m.dhhmmss shape."

# --- protected branch matching ----------------------------------------------

branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}"

is_protected="false"
while IFS= read -r pattern; do
  pattern="$(printf '%s' "$pattern" | xargs)"
  [[ -n "$pattern" ]] || continue
  # shellcheck disable=SC2053 # unquoted RHS is deliberate: enables globbing
  if [[ "$branch" == $pattern ]]; then
    is_protected="true"
    break
  fi
done <<<"$(tr ',' '\n' <<<"$PROTECTED_BRANCHES")"

# A pull request is always a prerelease, even when it originates from a
# protected branch -- the commit it describes has not landed yet.
if [[ "$EVENT_NAME" == pull_request* || "$is_protected" != "true" ]]; then
  is_prerelease="true"
else
  is_prerelease="false"
fi

if [[ -n "$VERSION_OVERRIDE" ]]; then
  version="$VERSION_OVERRIDE"
  [[ "$version" == *-* ]] && is_prerelease="true"
  log "Using explicit version override '$version' (computed value would have been '$calver')."
elif [[ "$is_prerelease" == "true" ]]; then
  # The `g` prefix follows `git describe`. Without it a short sha that is all
  # digits with a leading zero (e.g. 0123456) is an invalid semver numeric
  # prerelease identifier -- roughly one commit in 270.
  version="${calver}-g${short_sha}"
else
  version="$calver"
fi

tag="${TAG_PREFIX}${version}"

# --- tag collision and monotonicity -----------------------------------------

tag_exists="false"

remote_reachable="true"
git ls-remote --exit-code --quiet "$REMOTE" >/dev/null 2>&1 || remote_reachable="false"

if [[ "$is_prerelease" == "true" ]]; then
  log "Prerelease build; skipping tag collision and monotonicity checks."
elif [[ "$remote_reachable" != "true" ]]; then
  warn "Remote '$REMOTE' is unreachable; skipping tag collision and monotonicity checks."
else
  # An annotated tag advertises both refs/tags/X (the tag object) and
  # refs/tags/X^{} (the commit it peels to); prefer the peeled line.
  tagged_sha=""
  while IFS=$'\t' read -r object refname; do
    [[ -n "${refname:-}" ]] || continue
    if [[ "$refname" == *'^{}' ]]; then
      tagged_sha="$object"
      break
    fi
    tagged_sha="$object"
  done <<<"$(git ls-remote "$REMOTE" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null || true)"

  if [[ -z "$tagged_sha" ]]; then
    log "Tag '$tag' does not exist yet."
  elif [[ "$tagged_sha" == "$commit_sha" ]]; then
    tag_exists="true"
    log "Tag '$tag' already points at $commit_sha; nothing to release (idempotent re-run)."
  else
    die "Version collision: tag '$tag' already points at $tagged_sha but this run is for $commit_sha. Two commits share a committer second, or history was rewritten."
  fi

  if [[ "$NON_MONOTONIC" != "ignore" ]]; then
    # sort -V, never plain sort: lexically '2026.9.9235959' sorts above
    # '2026.10.1000005' even though it is the older version.
    prefix_re="$(printf '%s' "$TAG_PREFIX" | sed 's/[][\.*^$\/&]/\\&/g')"
    highest="$(
      git ls-remote --tags --refs "$REMOTE" 2>/dev/null \
        | sed "s#.*refs/tags/##" \
        | sed -n "s/^${prefix_re}//p" \
        | grep -E "$CALVER_RE" \
        | sort -V \
        | tail -n 1 || true
    )"
    if [[ -n "$highest" && "$(printf '%s\n%s\n' "$highest" "$calver" | sort -V | tail -n 1)" != "$calver" ]]; then
      message="Version '$calver' is older than the latest released version '$highest'. The commit's committer date predates an existing release (locally-made commits pushed directly, or rewritten history)."
      if [[ "$NON_MONOTONIC" == "fail" ]]; then
        die "$message"
      fi
      warn "$message"
    fi
  fi
fi

# --- emit outputs -----------------------------------------------------------

log "Computed version '$version' for commit $commit_sha (branch '$branch', event '$EVENT_NAME')."

printf '%s\n' \
  "version=$version" \
  "tag=$tag" \
  "is_prerelease=$is_prerelease" \
  "is_protected=$is_protected" \
  "tag_exists=$tag_exists" \
  "commit_sha=$commit_sha" \
  "short_sha=$short_sha" \
  "commit_date=$commit_date" \
  "branch=$branch"
