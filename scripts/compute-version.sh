#!/usr/bin/env bash
#
# Computes a semantic version for the commit being built.
#
#   channel=dev      X.Y.Z-g<shortsha>   every push; never tagged
#   channel=rc       X.Y.Z-rc.N          cut from a release/X.Y branch
#   channel=release  X.Y.Z               promotion of an existing rc
#
# On dev the number comes from semantic-release, which reads Conventional Commit
# messages since the last tag. On a release/X.Y branch the line is already fixed by
# the branch name, so the base is derived from the branch plus existing tags -- pure
# git and bash, no Node, no network.
#
# Configured through INPUT_* environment variables, reads the GitHub Actions context
# from GITHUB_*, and writes `key=value` lines to stdout. All diagnostics go to stderr
# so stdout can be appended to $GITHUB_OUTPUT.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHANNEL="${INPUT_CHANNEL:-dev}"
PROMOTE_FROM="${INPUT_PROMOTE_FROM:-}"
# `-` rather than `:-` so an explicitly empty tag_prefix is honoured.
TAG_PREFIX="${INPUT_TAG_PREFIX-v}"
SHA_LENGTH="${INPUT_SHA_LENGTH:-7}"
VERSION_OVERRIDE="${INPUT_VERSION:-}"
REMOTE="${INPUT_REMOTE:-origin}"
# Lets the test suite stand in for the Node call, keeping the suite offline.
SEMVER_CMD="${SEMVER_CMD:-node $HERE/next-semver.mjs}"

SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
SERIES_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

log()  { printf '%s\n' "$*" >&2; }
warn() { printf '::warning::%s\n' "$*" >&2; }
die()  { printf '::error::%s\n' "$*" >&2; exit 1; }

# Highest of the versions on stdin, or empty. sort -V, never plain sort: lexically
# '1.9.0' sorts above '1.10.0' even though it is older.
highest() { sort -V | tail -n 1; }

# --- validate configuration -------------------------------------------------

case "$CHANNEL" in
  dev|rc|release) ;;
  *) die "channel must be one of dev, rc, release; got '$CHANNEL'." ;;
esac

[[ "$SHA_LENGTH" =~ ^[0-9]+$ ]] || die "sha_length must be a number, got '$SHA_LENGTH'."
(( SHA_LENGTH >= 4 && SHA_LENGTH <= 40 )) || die "sha_length must be between 4 and 40, got '$SHA_LENGTH'."

git rev-parse --git-dir >/dev/null 2>&1 \
  || die "Not inside a git repository. Run actions/checkout before this action."

# --- resolve the commit and branch ------------------------------------------

commit_sha="$(git rev-parse 'HEAD^{commit}')"
# Plain truncation rather than `rev-parse --short`, whose length varies with
# repository size and core.abbrev and would make the version non-deterministic.
short_sha="${commit_sha:0:SHA_LENGTH}"
commit_date="$(TZ=UTC git show -s --format=%cd --date=format-local:'%Y-%m-%dT%H:%M:%SZ' "$commit_sha")"

branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}}"
head_branch="$(git rev-parse --abbrev-ref HEAD)"

# semantic-release reads the branch from the working tree, so a detached HEAD makes
# it report "no release" rather than failing. Only the dev channel consults it; the
# other two derive everything from refs and are safe while detached.
if [[ "$CHANNEL" == "dev" && "$head_branch" == "HEAD" ]]; then
  die "HEAD is detached. Version the branch itself (a push build), not a tag or a pull_request merge ref."
fi

# --- helpers over the tag namespace -----------------------------------------

prefix_re="$(printf '%s' "$TAG_PREFIX" | sed 's/[][\.*^$\/&]/\\&/g')"

# Released versions on this branch's history for a given X.Y series. `--merged HEAD`
# matters: a tag cut on an unrelated branch must not raise this branch's base.
series_releases() {
  git tag --merged HEAD --list "${TAG_PREFIX}${1}.*" 2>/dev/null \
    | sed -n "s/^${prefix_re}//p" \
    | grep -E "$SEMVER_RE" || true
}

# Existing rc numbers for an exact base version.
rc_numbers() {
  git tag --merged HEAD --list "${TAG_PREFIX}${1}-rc.*" 2>/dev/null \
    | sed -n "s/^${prefix_re}${1}-rc\.\([0-9][0-9]*\)$/\1/p" || true
}

# Newest release reachable from HEAD, prerelease suffixes ignored.
last_release() {
  git tag --merged HEAD --list "${TAG_PREFIX}*" 2>/dev/null \
    | sed -n "s/^${prefix_re}//p" \
    | grep -E "$SEMVER_RE" \
    | highest || true
}

bump_patch() {
  local major minor patch
  IFS=. read -r major minor patch <<<"$1"
  printf '%s.%s.%s' "$major" "$minor" "$((patch + 1))"
}

# --- base version -----------------------------------------------------------

series=""
if [[ "$branch" =~ ^release/(.+)$ ]]; then
  series="${BASH_REMATCH[1]}"
  [[ "$series" =~ $SERIES_RE ]] \
    || die "Release branch '$branch' must be named release/<major>.<minor>, e.g. release/1.4."
fi

has_release="true"
release_type=""
last_version=""

if [[ "$CHANNEL" == "release" ]]; then
  # A promotion takes its version from the candidate it promotes, so there is
  # nothing to derive here and no branch to derive it from -- promote.yml checks
  # the rc tag out directly, leaving HEAD detached.
  base_version=""
  log "Promotion of '$PROMOTE_FROM'; the version comes from the candidate."
elif [[ -n "$series" ]]; then
  # The branch names the line, so the base never depends on commit messages.
  last_version="$(series_releases "$series" | highest)"
  if [[ -n "$last_version" ]]; then
    base_version="$(bump_patch "$last_version")"
  else
    base_version="${series}.0"
  fi
  log "Release branch '$branch': series $series, last release '${last_version:-none}', base $base_version."
else
  last_version="$(last_release)"

  mirror="$(mktemp -d)/mirror.git"
  trap 'rm -rf "$(dirname "$mirror")"' EXIT
  # semantic-release verifies push permission before it will compute anything, and
  # that check is not skipped in dry-run mode. Pointing it at a throwaway bare
  # mirror satisfies the check with no credentials at all -- and means a genuine
  # auth problem can never be misreported as "nothing to release".
  git clone --mirror --quiet "$(git rev-parse --show-toplevel)" "$mirror" \
    || die "Could not mirror the repository for version analysis."

  out="$(mktemp)"
  if ! SR_BRANCH="$head_branch" SR_REPO_URL="file://$mirror" \
       SR_CWD="$(git rev-parse --show-toplevel)" SR_OUT="$out" \
       SR_TAG_FORMAT="${TAG_PREFIX}\${version}" \
       $SEMVER_CMD >&2; then
    die "semantic-release failed to analyse the commit history; see the log above."
  fi

  next="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$out")"
  release_type="$(sed -n 's/.*"type":"\([^"]*\)".*/\1/p' "$out")"
  rm -f "$out"

  if [[ -n "$next" ]]; then
    base_version="$next"
  else
    # Nothing releasable. Still produce a version so the image keeps building --
    # has_release is what gates tagging.
    has_release="false"
    base_version="$(bump_patch "${last_version:-0.0.0}")"
    log "No releasable commit since '${last_version:-the start of history}'; using $base_version for this build only."
  fi

  # A cut release/X.Y branch owns the X.Y line, so trunk must move past it. Without
  # this, main keeps computing X.Y.0 until the release is tagged and merged back.
  floor_series="$(
    git ls-remote --heads "$REMOTE" 'refs/heads/release/*' 2>/dev/null \
      | sed 's@.*refs/heads/release/@@' \
      | grep -E "$SERIES_RE" \
      | sort -t. -k1,1n -k2,2n \
      | tail -n 1 || true
  )"
  if [[ -n "$floor_series" ]]; then
    floor="${floor_series%%.*}.$(( ${floor_series#*.} + 1 )).0"
    if [[ "$(printf '%s\n%s\n' "$base_version" "$floor" | highest)" == "$floor" \
          && "$base_version" != "$floor" ]]; then
      log "Release branch 'release/$floor_series' owns that line; raising base from $base_version to $floor."
      base_version="$floor"
    fi
  fi
fi

if [[ -n "$base_version" ]]; then
  [[ "$base_version" =~ $SEMVER_RE ]] \
    || die "Computed base version '$base_version' is not a plain X.Y.Z."
fi

# --- apply the channel ------------------------------------------------------

rc_number=""
tag_exists="false"

case "$CHANNEL" in
  dev)
    # The `g` follows `git describe`. Without it a short sha that is all digits with
    # a leading zero is an invalid semver prerelease identifier -- about one commit
    # in 270.
    version="${base_version}-g${short_sha}"
    is_prerelease="true"
    ;;

  rc)
    [[ -n "$series" ]] \
      || die "channel 'rc' must run on a release/<major>.<minor> branch; this is '$branch'."

    # An rc already on this commit is reused, so re-dispatching is a no-op instead of
    # minting a second candidate for identical code.
    existing="$(
      git tag --points-at HEAD --list "${TAG_PREFIX}${base_version}-rc.*" 2>/dev/null \
        | sed -n "s/^${prefix_re}${base_version}-rc\.\([0-9][0-9]*\)$/\1/p" \
        | sort -n | tail -n 1 || true
    )"
    if [[ -n "$existing" ]]; then
      rc_number="$existing"
      tag_exists="true"
      log "Commit $commit_sha already carries rc.$rc_number for $base_version; reusing it."
    else
      highest_rc="$(rc_numbers "$base_version" | sort -n | tail -n 1 || true)"
      rc_number="$(( ${highest_rc:-0} + 1 ))"
    fi
    version="${base_version}-rc.${rc_number}"
    is_prerelease="true"
    ;;

  release)
    [[ -n "$PROMOTE_FROM" ]] \
      || die "channel 'release' requires promote_from, the rc tag being promoted."

    rc_version="${PROMOTE_FROM#"$TAG_PREFIX"}"
    [[ "$rc_version" =~ ^(.+)-rc\.([0-9]+)$ ]] \
      || die "promote_from '$PROMOTE_FROM' is not a <version>-rc.<n> tag."
    version="${BASH_REMATCH[1]}"
    rc_number="${BASH_REMATCH[2]}"

    [[ "$version" =~ $SEMVER_RE ]] \
      || die "promote_from '$PROMOTE_FROM' does not carry a plain X.Y.Z version."

    git rev-parse -q --verify "refs/tags/${PROMOTE_FROM}" >/dev/null \
      || die "Tag '$PROMOTE_FROM' does not exist. Fetch tags, or cut the rc first."

    if git rev-parse -q --verify "refs/tags/${TAG_PREFIX}${version}" >/dev/null; then
      tag_exists="true"
      log "Tag '${TAG_PREFIX}${version}' already exists; promotion is a no-op."
    fi

    base_version="$version"
    is_prerelease="false"
    ;;
esac

if [[ -n "$VERSION_OVERRIDE" ]]; then
  log "Using explicit version override '$VERSION_OVERRIDE' (computed value would have been '$version')."
  version="$VERSION_OVERRIDE"
  [[ "$version" == *-* ]] && is_prerelease="true" || is_prerelease="false"
fi

tag="${TAG_PREFIX}${version}"

# --- emit outputs -----------------------------------------------------------

log "Computed version '$version' for commit $commit_sha (branch '$branch', channel '$CHANNEL')."

printf '%s\n' \
  "version=$version" \
  "base_version=$base_version" \
  "tag=$tag" \
  "rc_number=$rc_number" \
  "is_prerelease=$is_prerelease" \
  "has_release=$has_release" \
  "release_type=$release_type" \
  "last_version=$last_version" \
  "tag_exists=$tag_exists" \
  "commit_sha=$commit_sha" \
  "short_sha=$short_sha" \
  "commit_date=$commit_date" \
  "branch=$branch"
