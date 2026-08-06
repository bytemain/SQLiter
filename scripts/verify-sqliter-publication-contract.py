#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument(
    "--root-only",
    action="store_true",
    help="verify only the locally stageable root publication",
)
args = parser.parse_args()
VERSION = next(
    line.split("=", 1)[1].strip()
    for line in (ROOT / "gradle.properties").read_text().splitlines()
    if line.startswith("VERSION_NAME=")
)
SOURCE_SHA = subprocess.run(
    ["git", "rev-parse", "HEAD"],
    cwd=ROOT,
    check=True,
    capture_output=True,
    text=True,
).stdout.strip()
if not re.fullmatch(r"[0-9a-f]{40}", SOURCE_SHA):
    raise SystemExit("could not resolve exact SQLiter source SHA")

build = (ROOT / "sqliter-driver/build.gradle.kts").read_text()
state = (ROOT / "scripts/sqliter-publication-state.sh").read_text()
state_test = (ROOT / "scripts/test-sqliter-publication-state.sh").read_text()
publisher = (ROOT / "scripts/publish-sqliter.sh").read_text()
workflow = (ROOT / ".github/workflows/ohos-publication.yml").read_text()
build_workflow = (ROOT / ".github/workflows/build.yml").read_text()
required_source_fragments = (
    'dependsOn(commonMain)',
    'dependsOn(commonTest)',
    'name = "raftArtifacts"',
    'name = "publicationStaging"',
    'properties.put("dev.raft.sourceSha", publicationSourceSha)',
    "isPreserveFileTimestamps = false",
    "isReproducibleFileOrder = true",
)
for fragment in required_source_fragments:
    if fragment not in build:
        raise SystemExit(f"missing SQLiter publication contract fragment: {fragment}")
if 'name = "githubPackages"' in build or "GithubPackagesRepository" in build:
    raise SystemExit("SQLiter must not configure GitHub Packages as a publication target")

required_state_fragments = (
    "Raft Artifacts repository positive control failed",
    "partial immutable publication",
)
for fragment in required_state_fragments:
    if fragment not in state:
        raise SystemExit(f"missing SQLiter immutable-state guard: {fragment}")

for scenario in ('"absent"', '"complete"', '"partial"'):
    if scenario not in state_test:
        raise SystemExit(f"immutable-state test lacks scenario: {scenario}")
if '"split"' in state_test:
    raise SystemExit("single-repository SQLiter state test must not retain a split state")

required_publish_fragments = (
    'SQLITER_PLAN_READY:-}',
    "publication requires a clean checkout",
    "PUBLICATION_SOURCE_SHA must equal the clean checkout HEAD",
    "RAFT_ARTIFACTS_PUBLISH_TOKEN is required",
)
for fragment in required_publish_fragments:
    if fragment not in publisher:
        raise SystemExit(f"missing SQLiter publish guard: {fragment}")

required_workflow_fragments = (
    "sqliter-v*",
    "if: startsWith(github.ref, 'refs/tags/sqliter-v')",
    "environment: raft-artifacts-production",
    "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
    'test "$source_sha" = "${{ github.event.pull_request.head.sha || github.sha }}"',
    "name: sqliter-ohos-publication-${{ steps.source.outputs.sha }}",
    'git config --global --add safe.directory "$GITHUB_WORKSPACE"',
    "harmonyos-ci-image:v6.1.1.280@sha256:cbe95055b155c4eb71d234f24b47d481a1b20b7e96defe3f24ab3219aff55347",
)
for fragment in required_workflow_fragments:
    if fragment not in workflow:
        raise SystemExit(f"missing SQLiter Hosted guard: {fragment}")
for forbidden in (
    "packages: write",
    "GithubPackagesRepository",
    "GITHUB_PACKAGES_TOKEN",
    "secrets.GITHUB_TOKEN",
):
    if forbidden in workflow:
        raise SystemExit(f"SQLiter Hosted must be Raft-only, found: {forbidden}")

for fragment in (
    "runs-on: ubuntu-latest",
    "ref: ${{ github.event.pull_request.head.sha || github.sha }}",
    'test "$(git rev-parse HEAD)" = "${{ github.event.pull_request.head.sha || github.sha }}"',
    "test -d \"$ohos_sdk_home/native/sysroot\"",
    "harmonyos-ci-image:v6.1.1.280@sha256:cbe95055b155c4eb71d234f24b47d481a1b20b7e96defe3f24ab3219aff55347",
):
    if fragment not in build_workflow:
        raise SystemExit(f"legacy SQLiter build is not pinned to OHOS CI: {fragment}")

staging = ROOT / "sqliter-driver/build/publication-staging"
root_dir = staging / "co/touchlab/sqliter-driver" / VERSION
module_path = root_dir / f"sqliter-driver-{VERSION}.module"
pom_path = root_dir / f"sqliter-driver-{VERSION}.pom"
if not module_path.is_file() or not pom_path.is_file():
    raise SystemExit("staged SQLiter root POM/module are missing")
module = json.loads(module_path.read_text())
variants = module.get("variants", [])
if len(variants) != 4:
    raise SystemExit(f"SQLiter root must expose exactly 4 variants, got {len(variants)}")
available = {
    (
        variant["available-at"]["group"],
        variant["available-at"]["module"],
        variant["available-at"]["version"],
    )
    for variant in variants
    if "available-at" in variant
}
expected_available = {("co.touchlab", "sqliter-driver-ohosarm64", VERSION)}
if available != expected_available:
    raise SystemExit(f"unexpected SQLiter physical targets: {sorted(available)}")

def verify_pom(path: Path, artifact: str) -> None:
    pom = path.read_text()
    source_match = re.search(
        r"<dev\.raft\.sourceSha>([0-9a-f]{40})</dev\.raft\.sourceSha>", pom
    )
    tag_match = re.search(r"<tag>([0-9a-f]{40})</tag>", pom)
    if not source_match or not tag_match:
        raise SystemExit(f"{artifact} POM lacks exact sourceSha/SCM provenance")
    if source_match.group(1) != SOURCE_SHA or tag_match.group(1) != SOURCE_SHA:
        raise SystemExit(f"{artifact} POM provenance does not match checkout HEAD")


verify_pom(pom_path, "sqliter-driver")

root_base = Path("co/touchlab/sqliter-driver") / VERSION / f"sqliter-driver-{VERSION}"
target_base = (
    Path("co/touchlab/sqliter-driver-ohosarm64")
    / VERSION
    / f"sqliter-driver-ohosarm64-{VERSION}"
)
expected = {
    Path(f"{root_base}.jar"),
    Path(f"{root_base}.pom"),
    Path(f"{root_base}.module"),
    Path(f"{root_base}-sources.jar"),
    Path(f"{root_base}-javadoc.jar"),
    Path(f"{root_base}-kotlin-tooling-metadata.json"),
}
if not args.root_only:
    expected.update(
        {
            Path(f"{target_base}.klib"),
            Path(f"{target_base}-cinterop-sqlite3.klib"),
            Path(f"{target_base}.pom"),
            Path(f"{target_base}.module"),
            Path(f"{target_base}-sources.jar"),
            Path(f"{target_base}-javadoc.jar"),
        }
    )

actual = {
    path.relative_to(staging)
    for path in staging.rglob("*")
    if path.is_file()
    and not path.name.endswith((".md5", ".sha1", ".sha256", ".sha512"))
    and not path.name.startswith("maven-metadata.xml")
}
if actual != expected:
    missing = sorted(str(path) for path in expected - actual)
    extra = sorted(str(path) for path in actual - expected)
    raise SystemExit(f"SQLiter staged primary-file manifest mismatch: missing={missing} extra={extra}")

if not args.root_only:
    target_dir = staging / "co/touchlab/sqliter-driver-ohosarm64" / VERSION
    target_pom = target_dir / f"sqliter-driver-ohosarm64-{VERSION}.pom"
    target_module = target_dir / f"sqliter-driver-ohosarm64-{VERSION}.module"
    verify_pom(target_pom, "sqliter-driver-ohosarm64")
    parsed_target = json.loads(target_module.read_text())
    component = parsed_target.get("component", {})
    component_identity = (
        component.get("group"),
        component.get("module"),
        component.get("version"),
    )
    expected_component = ("co.touchlab", "sqliter-driver", VERSION)
    if component_identity != expected_component:
        raise SystemExit(
            "physical OHOS module must identify the exact SQLiter root component: "
            f"got={component_identity} expected={expected_component}"
        )

scope = "root" if args.root_only else "complete"
print(
    f"SQLiter OHOS-only {scope} contract PASS: version={VERSION} "
    f"source={SOURCE_SHA} variants=4 target=ohosArm64 files={len(expected)}"
)
