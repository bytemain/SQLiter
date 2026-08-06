#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/sqliter-publication-manifest.sh"
cd "$PROJECT_DIR"

if [[ "${SQLITER_PLAN_READY:-}" != "true" ]]; then
  echo "A successful immutable-state plan is required before publication." >&2
  exit 1
fi
if [[ "${SQLITER_SKIP_PUBLISH:-false}" == "true" ]]; then
  echo "SQLiter publication is already complete in Raft Artifacts."
  exit 0
fi
if [[ -z "${RAFT_ARTIFACTS_PUBLISH_TOKEN:-}" ]]; then
  echo "RAFT_ARTIFACTS_PUBLISH_TOKEN is required; publication fails closed." >&2
  exit 1
fi

git_config_home="$(mktemp -d)"
chmod 700 "$git_config_home"
cleanup() { rm -rf "$git_config_home"; }
trap cleanup EXIT
HOME="$git_config_home" git config --global --add safe.directory "$PROJECT_DIR"
publication_git() { HOME="$git_config_home" git "$@"; }

if [[ -n "$(publication_git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "SQLiter publication requires a clean checkout." >&2
  exit 1
fi
source_sha="$(publication_git rev-parse HEAD)"
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ || -n "${PUBLICATION_SOURCE_SHA:-}" && "$PUBLICATION_SOURCE_SHA" != "$source_sha" ]]; then
  echo "PUBLICATION_SOURCE_SHA must equal the clean checkout HEAD." >&2
  exit 1
fi
export PUBLICATION_SOURCE_SHA="$source_sha"

version="${SQLITER_VERSION:-$(sed -n 's/^VERSION_NAME=//p' gradle.properties | tail -n 1)}"
if [[ -z "$version" || "$version" == *SNAPSHOT* ]]; then
  echo "SQLITER_VERSION must be the immutable non-SNAPSHOT project version." >&2
  exit 1
fi

IFS=' ' read -r -a raft_tasks <<< "${SQLITER_RAFT_PUBLISH_TASKS:-}"
selected=()
for task in "${raft_tasks[@]}"; do
  [[ -n "$task" ]] || continue
  sqliter_assert_known_publication_task "$task"
  selected+=("$task")
done
if (( ${#selected[@]} == 0 )); then
  echo "Immutable SQLiter plan selected no publication tasks." >&2
  exit 1
fi

export RAFT_ARTIFACTS_USERNAME="${RAFT_ARTIFACTS_USERNAME:-raft-ci}"
export RAFT_ARTIFACTS_URL="${RAFT_ARTIFACTS_URL:-https://maven.artifacts.botiverse.dev}"

./gradlew --no-daemon --console=plain --max-workers=2 \
  -Dorg.gradle.jvmargs="-Xmx4g -XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8" \
  -PpublicationSourceSha="$source_sha" \
  "${selected[@]}"
