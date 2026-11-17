import json
from pathlib import Path
import subprocess
import tarfile

import pytest
import yaml

import release

REPOSITORY = "JensDerKrueger/BorgVR"
COMMIT = "a" * 40
IMAGE_ID = "sha256:" + "b" * 64


def build_artifact(output, version="3.9.0"):
    (output / release.ARCHIVE).write_bytes(b"test archive fixture")
    return release.prepare_bundle(output, release.metadata(REPOSITORY, COMMIT, version), IMAGE_ID)


def test_metadata_lowercase_image_and_branch_version_gate():
    result = release.metadata(REPOSITORY, COMMIT)
    assert result["image"] == "ghcr.io/jensderkrueger/borgvr-agent"
    assert result["version"] == "dev-" + COMMIT[:12]
    assert release.metadata(REPOSITORY, COMMIT, "3.9.0", True, "refs/heads/main")["version"] == "3.9.0"
    with pytest.raises(ValueError):
        release.metadata(REPOSITORY, COMMIT, "3.9.0", True, "refs/pull/1/merge")
    with pytest.raises(ValueError):
        release.metadata(REPOSITORY, COMMIT, "", True, "refs/heads/main")


@pytest.mark.parametrize("version", ["latest", "3.9;id", "3.9\nimage=evil", "../../3.9", "3.9.0/evil", " " * 100])
def test_invalid_release_versions(version):
    with pytest.raises(ValueError):
        release.metadata(REPOSITORY, COMMIT, version)


def test_deployment_allowlist_and_checksums(tmp_path):
    build_artifact(tmp_path)
    result = release.verify(tmp_path, REPOSITORY, COMMIT)
    assert result["published"] is False
    with tarfile.open(tmp_path / release.BUNDLE) as archive:
        names = archive.getnames()
        assert set(names) == {"borgvr-agent/" + name for name in (*release.DEPLOYMENT_FILES, "release.json", "INSTALL.md")}
        assert not any(".env" in name or "secrets/" in name or "runtime/" in name for name in names)
        install = archive.extractfile("borgvr-agent/INSTALL.md").read()
        assert b"--agent-image borgvr-agent:ci" in install
        assert b"sudo ./setup.sh init" in install and b"sudo ./setup.sh test" in install
        for name in ("setup.sh", "setup-host.sh", "uninstall.py"):
            assert archive.getmember("borgvr-agent/" + name).mode == 0o755
        assert b"bash setup" not in archive.extractfile("borgvr-agent/INSTALL.md").read()


@pytest.mark.parametrize("name", [release.ARCHIVE, release.BUNDLE, "release.json"])
def test_modified_artifacts_rejected(tmp_path, name):
    build_artifact(tmp_path)
    with (tmp_path / name).open("ab") as stream:
        stream.write(b"tampered")
    with pytest.raises(ValueError):
        release.verify(tmp_path, REPOSITORY, COMMIT)


def test_artifacts_cannot_switch_source_commit_or_repository(tmp_path):
    build_artifact(tmp_path)
    for repo, sha in (("other/repo", COMMIT), (REPOSITORY, "c" * 40)):
        with pytest.raises(ValueError):
            release.verify(tmp_path, repo, sha)


def test_checksum_names_cannot_escape_artifact_directory(tmp_path):
    build_artifact(tmp_path)
    (tmp_path / "SHA256SUMS").write_text("a" * 64 + "  ../private\n")
    with pytest.raises(ValueError):
        release.verify(tmp_path, REPOSITORY, COMMIT)


def test_loaded_image_must_match_tested_image(tmp_path, monkeypatch):
    build_artifact(tmp_path)
    monkeypatch.setattr(release, "command", lambda *args: "different" if "inspect" in args else "")
    with pytest.raises(ValueError):
        release.verify(tmp_path, REPOSITORY, COMMIT, load=True)


def publish_env(monkeypatch):
    for key, value in {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_SHA": COMMIT,
                       "GITHUB_REF": "refs/heads/main", "AGENT_VERSION": "3.9.0", "AGENT_PUBLISH": "true"}.items():
        monkeypatch.setenv(key, value)


def test_publication_requires_explicit_opt_in(tmp_path, monkeypatch):
    publish_env(monkeypatch)
    monkeypatch.setenv("AGENT_PUBLISH", "false")
    with pytest.raises(ValueError):
        release.publish(tmp_path)


def test_publisher_reuses_tested_image_and_pins_registry_digest(tmp_path, monkeypatch):
    info = build_artifact(tmp_path)
    publish_env(monkeypatch)
    reference = info["image"] + "@sha256:" + "d" * 64
    calls = []

    def command(*args):
        calls.append(args)
        if "inspect" in args:
            return json.dumps([reference]) if "{{json .RepoDigests}}" in args else IMAGE_ID
        return ""

    monkeypatch.setattr(release, "command", command)
    monkeypatch.setattr(release.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(args, 1, "", "manifest unknown"))
    release.publish(tmp_path)
    result = json.loads((tmp_path / "release.json").read_text())
    assert result["published"] is True and result["image_reference"] == reference
    assert any(call == ("docker", "push", info["image"] + ":3.9.0") for call in calls)
    assert not any("build" in call for call in calls)
    assert release.ARCHIVE not in (tmp_path / "SHA256SUMS").read_text()
    with tarfile.open(tmp_path / release.BUNDLE) as archive:
        assert reference.encode() in archive.extractfile("borgvr-agent/INSTALL.md").read()


def test_publisher_refuses_replacing_a_different_version(tmp_path, monkeypatch):
    build_artifact(tmp_path)
    publish_env(monkeypatch)
    calls = []
    monkeypatch.setattr(release, "command", lambda *args: calls.append(args) or (IMAGE_ID if "inspect" in args else ""))
    monkeypatch.setattr(release.subprocess, "run", lambda *args, **kwargs: subprocess.CompletedProcess(
        args, 0, json.dumps({"config": {"digest": "sha256:" + "e" * 64}}), ""))
    with pytest.raises(ValueError, match="different image"):
        release.publish(tmp_path)
    assert not any(call[-1].endswith(":3.9.0") and "push" in call for call in calls)


def test_workflow_is_readonly_until_manual_main_branch_publication():
    path = Path(__file__).resolve().parents[2] / ".github/workflows/borgvr-agent.yml"
    workflow = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
    assert workflow["permissions"] == {"contents": "read"}
    assert "pull_request_target" not in workflow["on"]
    assert workflow["on"]["workflow_dispatch"]["inputs"]["publish"]["default"] == "false"
    build, publish = workflow["jobs"]["build"], workflow["jobs"]["publish"]
    assert publish["permissions"] == {"contents": "read", "packages": "write"}
    assert "workflow_dispatch" in publish["if"] and "refs/heads/main" in publish["if"]
    assert "permissions" not in build
    for job in workflow["jobs"].values():
        for step in job["steps"]:
            if "uses" in step:
                assert len(step["uses"].split("@")[1]) == 40
    steps = build["steps"]
    smoke = next(i for i, step in enumerate(steps) if "container_smoke.py" in step.get("run", ""))
    upload = next(i for i, step in enumerate(steps) if step.get("id") == "upload")
    assert smoke < upload
