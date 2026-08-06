#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/sqliter-publication-manifest.sh"

mode="${1:-plan}"
if [[ "$mode" != "plan" && "$mode" != "verify" ]]; then
  echo "Usage: $0 [plan|verify]" >&2
  exit 2
fi

version="${SQLITER_VERSION:-$(sed -n 's/^VERSION_NAME=//p' "$PROJECT_DIR/gradle.properties" | tail -n 1)}"
if [[ -z "$version" || "$version" == *SNAPSHOT* ]]; then
  echo "SQLITER_VERSION must be a non-SNAPSHOT version." >&2
  exit 1
fi

required_text="${SQLITER_REQUIRED_TASKS:-${SQLITER_DEFAULT_REQUIRED_TASKS[*]}}"
IFS=' ' read -r -a required_tasks <<< "$required_text"
if (( ${#required_tasks[@]} == 0 )); then
  echo "At least one SQLiter publication task is required." >&2
  exit 1
fi
declare -A seen=()
for task in "${required_tasks[@]}"; do
  sqliter_assert_known_publication_task "$task"
  if [[ -n "${seen[$task]:-}" ]]; then
    echo "Duplicate SQLiter publication task: $task" >&2
    exit 1
  fi
  seen[$task]=1
done

github_repository="${GITHUB_REPOSITORY:-}"
github_username="${GITHUB_PACKAGES_USERNAME:-${GITHUB_ACTOR:-}}"
github_token="${GITHUB_PACKAGES_TOKEN:-${GITHUB_TOKEN:-}}"
raft_base_url="${RAFT_ARTIFACTS_URL:-https://maven.artifacts.botiverse.dev}"
raft_base_url="${raft_base_url%/}"
raft_browser_url="${RAFT_ARTIFACTS_BROWSER_URL:-https://artifacts.botiverse.dev}"
raft_browser_url="${raft_browser_url%/}"
if [[ -z "$github_repository" || -z "$github_username" || -z "$github_token" ]]; then
  echo "GITHUB_REPOSITORY and GitHub Packages credentials are required." >&2
  exit 1
fi

github_netrc="$(mktemp)"
chmod 600 "$github_netrc"
printf 'machine maven.pkg.github.com\nlogin %s\npassword %s\n' \
  "$github_username" "$github_token" > "$github_netrc"
printf 'machine api.github.com\nlogin %s\npassword %s\n' \
  "$github_username" "$github_token" >> "$github_netrc"
cleanup() {
  if command -v shred >/dev/null 2>&1; then
    shred -u "$github_netrc"
  else
    rm -f "$github_netrc"
  fi
}
trap cleanup EXIT

curl_retry_args=(--retry 2)
if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
  curl_retry_args+=(--retry-all-errors)
fi

curl_code() {
  local destination="$1"
  local relative_path="$2"
  local base_url
  local -a auth_args=()
  case "$destination" in
    github)
      base_url="https://maven.pkg.github.com/$github_repository"
      auth_args=(--netrc-file "$github_netrc")
      ;;
    raft)
      base_url="$raft_base_url"
      ;;
    *) echo "Unknown destination: $destination" >&2; return 1 ;;
  esac
  curl --silent --show-error --head --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 15 --max-time 60 "${curl_retry_args[@]}" \
    "${auth_args[@]}" "$base_url/$relative_path"
}

github_owner="${github_repository%%/*}"
if [[ -z "$github_owner" || "$github_owner" == "$github_repository" ]]; then
  echo "GITHUB_REPOSITORY must have owner/name form." >&2
  exit 1
fi
github_api_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 15 --max-time 60 "${curl_retry_args[@]}" \
  --netrc-file "$github_netrc" -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/orgs/$github_owner/packages?package_type=maven&per_page=1")"
if [[ "$github_api_code" != "200" ]]; then
  echo "GitHub Packages read-scope positive control failed with HTTP $github_api_code." >&2
  exit 1
fi
raft_control_code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
  --connect-timeout 15 --max-time 60 "${curl_retry_args[@]}" \
  "$raft_browser_url/scopes/com.tencent.kuiklybase")"
if [[ "$raft_control_code" != "200" ]]; then
  echo "Raft Artifacts repository positive control failed with HTTP $raft_control_code." >&2
  exit 1
fi

classify_task() {
  local destination="$1"
  local task="$2"
  local present=0 missing=0 total=0 path code
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    total=$((total + 1))
    code="$(curl_code "$destination" "$path")"
    case "$code" in
      200) present=$((present + 1)) ;;
      404) missing=$((missing + 1)) ;;
      *) echo "$destination probe for $task failed with HTTP $code." >&2; return 1 ;;
    esac
  done < <(sqliter_required_paths_for "$task" "$version")
  if (( total == 0 )); then
    echo "SQLiter manifest returned no paths for $task." >&2
    return 1
  elif (( present == total )); then
    printf 'complete\n'
  elif (( missing == total )); then
    printf 'absent\n'
  else
    echo "$destination has a partial immutable publication for $task ($present/$total); refusing overwrite/retry." >&2
    return 1
  fi
}

github_missing=()
raft_missing=()
for task in "${required_tasks[@]}"; do
  github_state="$(classify_task github "$task")"
  raft_state="$(classify_task raft "$task")"
  echo "$task: github=$github_state raft=$raft_state"
  if [[ "$github_state" != "$raft_state" ]]; then
    echo "Split repository state for $task requires a separately reviewed exact-byte recovery; source rebuild is forbidden." >&2
    exit 1
  fi
  [[ "$github_state" == "absent" ]] && github_missing+=("$task")
  [[ "$raft_state" == "absent" ]] && raft_missing+=("$task")
done

if [[ "$mode" == "verify" ]]; then
  if (( ${#github_missing[@]} || ${#raft_missing[@]} )); then
    echo "SQLiter dual publication did not converge." >&2
    exit 1
  fi
  echo "All required SQLiter files exist in both repositories."
  exit 0
fi

github_text="${github_missing[*]:-}"
raft_text="${raft_missing[*]:-}"
skip=false
if (( ${#github_missing[@]} == 0 && ${#raft_missing[@]} == 0 )); then
  skip=true
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'SQLITER_GITHUB_PUBLISH_TASKS=%s\n' "$github_text" >> "$GITHUB_ENV"
  printf 'SQLITER_RAFT_PUBLISH_TASKS=%s\n' "$raft_text" >> "$GITHUB_ENV"
  printf 'SQLITER_SKIP_PUBLISH=%s\n' "$skip" >> "$GITHUB_ENV"
  printf 'SQLITER_PLAN_READY=true\n' >> "$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'skipped=%s\n' "$skip" >> "$GITHUB_OUTPUT"
fi
echo "Immutable SQLiter plan: missing=${#github_missing[@]} skipped=$skip."
