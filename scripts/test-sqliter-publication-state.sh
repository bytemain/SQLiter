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
    https://api.github.com/orgs/bytemain/packages* | \
    https://artifacts.botiverse.dev/scopes/com.tencent.kuiklybase)
      printf '200'
      ;;
    https://maven.pkg.github.com/*)
      case "${SQLITER_MOCK_STATE:?}" in
        absent) printf '404' ;;
        complete | split) printf '200' ;;
        partial)
          [[ "$url" == *.pom ]] && printf '200' || printf '404'
          ;;
        *) return 2 ;;
      esac
      ;;
    https://maven.artifacts.botiverse.dev/*)
      case "${SQLITER_MOCK_STATE:?}" in
        absent | split) printf '404' ;;
        complete) printf '200' ;;
        partial)
          [[ "$url" == *.pom ]] && printf '200' || printf '404'
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
  GITHUB_REPOSITORY GITHUB_PACKAGES_USERNAME GITHUB_PACKAGES_TOKEN \
  GITHUB_ACTOR GITHUB_TOKEN
if publisher_output="$("$SCRIPT_DIR/publish-sqliter.sh" 2>&1)"; then
  echo "publisher ran without an immutable-state plan" >&2
  exit 1
fi
grep -Fq 'successful immutable-state plan is required' <<< "$publisher_output"

export SQLITER_PLAN_READY="true"
if publisher_output="$("$SCRIPT_DIR/publish-sqliter.sh" 2>&1)"; then
  echo "publisher ran without dual-repository credentials" >&2
  exit 1
fi
grep -Fq 'GitHub Packages credentials are required' <<< "$publisher_output"
unset SQLITER_PLAN_READY

export GITHUB_REPOSITORY="bytemain/SQLiter"
export GITHUB_PACKAGES_USERNAME="contract-test"
export GITHUB_PACKAGES_TOKEN="contract-test-token"
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
grep -Fq 'publishKotlinMultiplatformPublicationToGithubPackagesRepository' "$GITHUB_ENV"
grep -Fq 'publishOhosArm64PublicationToGithubPackagesRepository' "$GITHUB_ENV"

export SQLITER_MOCK_STATE="complete"
export GITHUB_ENV="$test_dir/complete.env"
"$SCRIPT_DIR/sqliter-publication-state.sh" plan >/dev/null
grep -Fxq 'SQLITER_SKIP_PUBLISH=true' "$GITHUB_ENV"
grep -Fxq 'SQLITER_PLAN_READY=true' "$GITHUB_ENV"

export SQLITER_MOCK_STATE="split"
if split_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" plan 2>&1)"; then
  echo "split GitHub/Raft state was not rejected" >&2
  exit 1
fi
grep -Fq 'Split repository state' <<< "$split_output"

export SQLITER_MOCK_STATE="partial"
if partial_output="$("$SCRIPT_DIR/sqliter-publication-state.sh" plan 2>&1)"; then
  echo "partial immutable publication was not rejected" >&2
  exit 1
fi
grep -Fq 'partial immutable publication' <<< "$partial_output"

echo "SQLiter immutable-state planner contract PASS"
