import json
from pathlib import Path
import subprocess
import sys

import pytest

import uninstall

OWN = "a" * 64
OTHER = "b" * 64
IMAGE = "registry.example.org/borgvr-agent:3.9"


class FakeDocker:
    def __init__(self, root):
        self.root, self.calls = root, []
        self.foreign_directory = False
        self.shared_volume = self.shared_network = self.shared_image = False
        self.fail_delete = False

    def run(self, *args, missing=False):
        self.calls.append(args)
        if self.fail_delete and "rm" in args:
            raise ValueError("Docker deletion failed")
        if args[:2] == ("ps", "-aq"):
            if any("volume=" in a for a in args):
                return OTHER if self.shared_volume else OWN
            if any("ancestor=" in a for a in args):
                return OTHER if self.shared_image else OWN
            return OWN
        if args[:2] == ("volume", "ls"):
            return "borgvr-ai_model-cache"
        if args[:2] == ("network", "ls"):
            return "c" * 64
        if args[:2] == ("image", "inspect"):
            return json.dumps([{"Id": "sha256:" + "d" * 64}]) if args[2] == IMAGE else None
        return ""

    def inspect(self, kind, identifiers):
        if kind == "container":
            return [{"Id": OWN, "Config": {"Image": IMAGE, "Labels": {
                uninstall.LABEL: uninstall.PROJECT,
                "com.docker.compose.project.working_dir": str(self.root / "other" if self.foreign_directory else self.root),
            }}}]
        if kind == "volume":
            return [{"Name": "borgvr-ai_model-cache", "Labels": {uninstall.LABEL: uninstall.PROJECT}}]
        if kind == "network":
            return [{"Id": "c" * 64, "Name": "borgvr-ai_default", "Labels": {uninstall.LABEL: uninstall.PROJECT},
                     "Containers": {OTHER if self.shared_network else OWN: {}}}]
        raise AssertionError(kind)


def local_files(root):
    (root / ".env").write_text("BORGVR_AGENT_IMAGE=" + IMAGE + "\n")
    (root / "runtime").mkdir()
    (root / "runtime/key").write_text("test secret")


def test_preview_never_deletes_resources(tmp_path, monkeypatch, capsys):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    monkeypatch.setattr(uninstall, "ROOT", tmp_path)
    monkeypatch.setattr(uninstall, "Docker", lambda: docker)
    monkeypatch.setattr(uninstall.shutil, "which", lambda _: "/fake/docker")
    monkeypatch.setattr(sys, "argv", ["uninstall.py", "--remove-images"])
    uninstall.main()
    assert "Preview only" in capsys.readouterr().out
    assert (tmp_path / "runtime/key").exists() and (tmp_path / ".env").exists()
    assert not any("rm" in call for call in docker.calls)


def test_cleanup_removes_only_project_resources_and_local_data(tmp_path):
    local_files(tmp_path)
    (tmp_path / "my-volume.data").write_text("keep")
    docker = FakeDocker(tmp_path)
    plan = uninstall.docker_plan(tmp_path, docker, True)
    assert plan["images"] == [IMAGE]
    uninstall.apply_plan(tmp_path, docker, plan)
    assert not (tmp_path / "runtime").exists() and not (tmp_path / ".env").exists()
    assert (tmp_path / "my-volume.data").read_text() == "keep"
    assert ("container", "rm", "--force", "--volumes", OWN) in docker.calls
    assert ("volume", "rm", "borgvr-ai_model-cache") in docker.calls
    assert ("image", "rm", IMAGE) in docker.calls
    assert not any("prune" in call or "--force" in call and "image" in call for call in docker.calls)


@pytest.mark.parametrize("attribute", ["foreign_directory", "shared_volume", "shared_network"])
def test_foreign_deployment_or_shared_resources_block_deletion(tmp_path, attribute):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    setattr(docker, attribute, True)
    with pytest.raises(ValueError):
        uninstall.docker_plan(tmp_path, docker, True)
    assert not any("rm" in call for call in docker.calls)
    assert (tmp_path / "runtime/key").exists()


def test_images_used_by_foreign_containers_are_kept(tmp_path):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    docker.shared_image = True
    plan = uninstall.docker_plan(tmp_path, docker, True)
    assert plan["images"] == [] and plan["shared_images_retained"] == [IMAGE]


def test_rocm_deployment_does_not_select_unrelated_cuda_image_for_removal(tmp_path):
    (tmp_path / ".env").write_text("BORGVR_VLLM_IMAGE=example.org/rocm:test\n")
    references = uninstall.image_references(tmp_path)
    assert "example.org/rocm:test" in references
    assert not any(reference.startswith("vllm/vllm-openai:") for reference in references)


def test_image_aliases_do_not_leave_version_or_digest_tags_behind(tmp_path):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    original = docker.run
    aliases = [IMAGE, "registry.example.org/borgvr-agent:sha-old"]
    digest = "registry.example.org/borgvr-agent@sha256:" + "e" * 64

    def run(*args, **kwargs):
        if args[:2] == ("image", "inspect") and args[2] == IMAGE:
            return json.dumps([{"Id": "sha256:" + "d" * 64, "RepoTags": aliases, "RepoDigests": [digest]}])
        return original(*args, **kwargs)

    docker.run = run
    assert set(uninstall.docker_plan(tmp_path, docker, True)["images"]) == set(aliases + [digest])


def test_failure_keeps_configuration_for_retry(tmp_path):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    plan = uninstall.docker_plan(tmp_path, docker, True)
    docker.fail_delete = True
    with pytest.raises(ValueError):
        uninstall.apply_plan(tmp_path, docker, plan)
    assert (tmp_path / "runtime/key").exists() and (tmp_path / ".env").exists()


def test_firewall_cleanup_precedes_removing_local_files(tmp_path, monkeypatch):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    plan = uninstall.docker_plan(tmp_path, docker, False)
    cleaned = []
    def cleanup(root):
        assert (root / ".env").exists() and (root / "runtime").is_dir()
        assert ("container", "rm", "--force", "--volumes", OWN) in docker.calls
        cleaned.append(root)
    monkeypatch.setattr(uninstall, "remove_rules", cleanup)
    uninstall.apply_plan(tmp_path, docker, plan)
    assert cleaned == [tmp_path] and not (tmp_path / "runtime").exists()


def test_firewall_cleanup_failure_keeps_configuration_for_retry(tmp_path, monkeypatch):
    local_files(tmp_path)
    docker = FakeDocker(tmp_path)
    plan = uninstall.docker_plan(tmp_path, docker, False)
    def fail(root):
        raise ValueError("Firewall service unavailable")
    monkeypatch.setattr(uninstall, "remove_rules", fail)
    with pytest.raises(ValueError, match="Firewall service unavailable"):
        uninstall.apply_plan(tmp_path, docker, plan)
    assert (tmp_path / "runtime/key").exists() and (tmp_path / ".env").exists()


def test_runtime_symlink_does_not_delete_external_files(tmp_path):
    outside, root = tmp_path / "outside", tmp_path / "deployment"
    outside.mkdir()
    root.mkdir()
    (outside / "keep").write_text("keep")
    (root / "runtime").symlink_to(outside, target_is_directory=True)
    uninstall.remove_local(root / "runtime")
    assert (outside / "keep").exists() and not (root / "runtime").exists()


def test_env_is_data_not_shell_code(tmp_path):
    (tmp_path / ".env").write_text("BORGVR_AGENT_IMAGE=$(touch private)\n")
    with pytest.raises(ValueError):
        uninstall.image_references(tmp_path)
    assert not (tmp_path / "private").exists()


def clone_fixture(tmp_path, origin="https://github.com/JensDerKrueger/BorgVR.git"):
    clone = tmp_path / "BorgVR"
    root = clone / "BorgVRAgentServer"
    root.mkdir(parents=True)
    def git(*args):
        return subprocess.run(["git", "-C", str(clone), *args], check=True, capture_output=True, text=True)
    git("init")
    git("remote", "add", "origin", origin)
    (clone / ".gitignore").write_text("*\n")
    return clone, root, git


def test_whole_checkout_deletion_is_explicit_and_scoped(tmp_path):
    clone, root, _ = clone_fixture(tmp_path)
    target = uninstall.checkout_target(root)
    assert target == clone
    (tmp_path / "unrelated").write_text("keep")
    plan = {key: [] for key in ("containers", "volumes", "networks", "images")}
    uninstall.apply_plan(root, None, plan, target)
    assert not clone.exists() and (tmp_path / "unrelated").exists()


def test_dirty_or_different_repository_is_not_deleted(tmp_path):
    clone, root, git = clone_fixture(tmp_path)
    (clone / "personal.txt").write_text("keep")
    git("add", "--force", "personal.txt")
    with pytest.raises(ValueError, match="local changes"):
        uninstall.checkout_target(root)
    assert (clone / "personal.txt").exists()
    git("remote", "set-url", "origin", "https://github.com/example/another.git")
    with pytest.raises(ValueError, match="different repository"):
        uninstall.checkout_target(root)


def test_bundle_directory_is_scoped_and_home_is_protected(tmp_path, monkeypatch):
    root = tmp_path / "borgvr-agent"
    root.mkdir()
    (root / "release.json").write_text(json.dumps({"repository": "JensDerKrueger/BorgVR"}))
    assert uninstall.checkout_target(root) == root
    monkeypatch.setattr(Path, "home", lambda: root)
    with pytest.raises(ValueError, match="home"):
        uninstall.checkout_target(root)


def test_docs_use_executable_commands_without_bash_labels():
    root = Path(__file__).resolve().parents[1]
    for name in ("README.md", "README.de.md"):
        text = (root / name).read_text()
        assert "```bash" not in text and "bash setup" not in text
        assert "./setup.sh uninstall" in text
    assert (root / "setup.sh").stat().st_mode & 0o111
    assert (root / "setup-host.sh").stat().st_mode & 0o111
    assert (root / "uninstall.py").stat().st_mode & 0o111
