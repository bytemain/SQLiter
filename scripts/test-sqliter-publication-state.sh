#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

curl() {
  if [[ "${1:-}" == "--help" ]]; then
    echo "--retry-all-errors"
    return 0
  fi

  local argument url=""
  for argument in "$@"; do
    if [[ "$argument" == http://* || "$argument" == https://* ]]; then
      url="$argument"
    fi
  done
  if [[ -z "$url" ]]; then
    echo "mock curl received no URL" >&2
    return 2
  fi

  case "$url" in
    https://artifacts.botiverse.dev/scopes/com.tencent.kuiklybase)
      printf '200'
      ;;
    https://maven.artifacts.botiverse.dev/*)
      case "${SQLITER_MOCK_STATE:?}" in
        absent) printf '404' ;;
        complete) printf '200' ;;
        partial)
          [[ "$url" == *.pom ]] && printf '200' || printf '404'
          ;;
        root_complete_target_absent)
          [[ "$url" == */sqliter-driver-ohosarm64/* ]] && printf '404' || printf '200'
          ;;
        root_absent_target_complete)
          [[ "$url" == */sqliter-driver-ohosarm64/* ]] && printf '200' || printf '404'
          ;;
        *) return 2 ;;
      esac
      ;;
    *)
      echo "unexpected mock URL: $url" >&2
      return 2
      ;;
  esac
}
export -f curl

unset \
  SQLITER_PLAN_READY SQLITER_SKIP_PUBLISH RAFT_ARTIFACTS_PUBLISH_TOKEN \
  SQLITER_RAFT_PUBLISH_TASKS SQLITER_REQUIRED_TASKS
if publisher_output="$("$SCRIPT_DIR/publish-sqliter.sh" 2>&1)"; then
  echo "publisher ran without an immutable-state plan" >&2
  exit 1
fi
grep -Fq 'successful immutable-state plan is required' <<< "$publisher_output"

export SQLITER_PLAN_READY="true"
if publisher_output="$("$SCRIPT_DIR/publish-sqliter.sh" 2>&1)"; then
  echo "publisher ran without Raft Artifacts credentials" >&2
  exit 1
fi
grep -Fq 'RAFT_ARTIFACTS_PUBLISH_TOKEN is required' <<< "$publisher_output"
unset SQLITER_PLAN_READY

export RAFT_ARTIFACTS_URL="https://maven.artifacts.botiverse.dev"
export RAFT_ARTIFACTS_BROWSER_URL="https://artifacts.botiverse.dev"

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

export SQLITER_MOCK_STATE="absent"
export GITHUB_ENV="$test_dir/absent.env"
"$SCRIPT_DIR/sqliter-publication-state.sh" plan >/dev/null
grep -Fxq 'SQLITER_SKIP_PUBLISH=false' "$GITHUB_ENV"
grep -Fxq 'SQLITER_PLAN_READY=true' "$GITHUB_ENV"
grep -Fq 'publishKotlinMultiplatformPublicationToRaftArtifactsRepository' "$GITHUB_ENV"
grep -Fq 'publishOhosArm64PublicationToRaftArtifactsRepository' "$GITHUB_ENV"

export SQLITER_MOCK_STATE="complete"
export GITHUB_ENV="$test_dir/complete.env"
"$SCRIPT_DIR/sqliter-publication-state.sh" plan >/dev/null
grep -Fxq 'SQLITER_SKIP_PUBLISH=true' "$GITHUB_ENV"
grep -Fxq 'SQLITER_PLAN_READY=true' "$GITHUB_ENV"
"$SCRIPT_DIR/sqliter-publication-state.sh" verify >/dev/null

export SQLITER_MOCK_STATE="absent"
if absent_verify_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" verify 2>&1)"; then
  echo "absent Raft publication passed verification" >&2
  exit 1
fi
grep -Fq 'did not converge' <<< "$absent_verify_output"

export SQLITER_MOCK_STATE="partial"
if partial_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" plan 2>&1)"; then
  echo "partial immutable publication was not rejected" >&2
  exit 1
fi
grep -Fq 'partial immutable publication' <<< "$partial_output"

for split_state in root_complete_target_absent root_absent_target_complete; do
  export SQLITER_MOCK_STATE="$split_state"
  if split_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" plan 2>&1)"; then
    echo "partial closed graph $split_state was not rejected" >&2
    exit 1
  fi
  grep -Fq 'partial closed SQLiter graph' <<< "$split_output"
done

export SQLITER_MOCK_STATE="absent"
export SQLITER_REQUIRED_TASKS=":sqliter-driver:publishKotlinMultiplatformPublicationToRaftArtifactsRepository"
if narrowed_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" plan 2>&1)"; then
  echo "externally narrowed SQLiter graph was not rejected" >&2
  exit 1
fi
grep -Fq 'complete two-task closed graph' <<< "$narrowed_output"
unset SQLITER_REQUIRED_TASKS

export SQLITER_PLAN_READY="true"
export RAFT_ARTIFACTS_PUBLISH_TOKEN="contract-test-token"
export SQLITER_RAFT_PUBLISH_TASKS=":sqliter-driver:publishKotlinMultiplatformPublicationToRaftArtifactsRepository"
if publisher_output="$("$SCRIPT_DIR/publish-sqliter.sh" 2>&1)"; then
  echo "publisher accepted a narrowed SQLiter graph" >&2
  exit 1
fi
grep -Fq 'complete two-task closed graph' <<< "$publisher_output"

echo "SQLiter immutable-state planner contract PASS"
