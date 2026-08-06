#!/usr/bin/env bash

SQLITER_DEFAULT_REQUIRED_TASKS=(
  ":sqliter-driver:publishKotlinMultiplatformPublicationToGithubPackagesRepository"
  ":sqliter-driver:publishOhosArm64PublicationToGithubPackagesRepository"
)

sqliter_assert_known_publication_task() {
  case "$1" in
    :sqliter-driver:publishKotlinMultiplatformPublicationToGithubPackagesRepository | \
    :sqliter-driver:publishOhosArm64PublicationToGithubPackagesRepository)
      return 0
      ;;
    *)
      echo "Unknown SQLiter publication task: $1" >&2
      return 1
      ;;
  esac
}

sqliter_task_for_repository() {
  local github_task="$1"
  local repository="$2"
  sqliter_assert_known_publication_task "$github_task"
  case "$repository" in
    github) printf '%s\n' "$github_task" ;;
    raft) printf '%s\n' "${github_task/GithubPackagesRepository/RaftArtifactsRepository}" ;;
    staging) printf '%s\n' "${github_task/GithubPackagesRepository/PublicationStagingRepository}" ;;
    *) echo "Unknown SQLiter repository: $repository" >&2; return 1 ;;
  esac
}

sqliter_required_paths_for() {
  local task="$1"
  local version="$2"
  sqliter_assert_known_publication_task "$task"
  case "$task" in
    :sqliter-driver:publishKotlinMultiplatformPublicationToGithubPackagesRepository)
      local base="co/touchlab/sqliter-driver/$version/sqliter-driver-$version"
      printf '%s\n' \
        "$base.jar" \
        "$base.pom" \
        "$base.module" \
        "$base-sources.jar" \
        "$base-javadoc.jar" \
        "$base-kotlin-tooling-metadata.json"
      ;;
    :sqliter-driver:publishOhosArm64PublicationToGithubPackagesRepository)
      local base="co/touchlab/sqliter-driver-ohosarm64/$version/sqliter-driver-ohosarm64-$version"
      printf '%s\n' \
        "$base.klib" \
        "$base-cinterop-sqlite3.klib" \
        "$base.pom" \
        "$base.module" \
        "$base-sources.jar" \
        "$base-javadoc.jar"
      ;;
  esac
}
