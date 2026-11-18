#!/usr/bin/env python3
"""Preview or remove this BorgVR deployment without global Docker prune operations."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from configure import DEFAULT_AGENT_IMAGE, PYTHON_IMAGE
from firewall import load_rules, remove_rules

ROOT = Path(__file__).resolve().parent
PROJECT = "borgvr-ai"
LABEL = "com.docker.compose.project"
LOCAL_FILES = ("runtime", ".env", ".venv", "__pycache__", ".pytest_cache")


def development_plan(root):
    if ((root / "runtime/agent-development.json").exists() or
        Path("/var/lib/borgvr-agent-dev/installation.json").exists()):
        from development import removal_plan
        return removal_plan(root)
    return None


class Docker:
    def run(self, *args, missing=False):
        result = subprocess.run(["docker", "--host", "unix:///var/run/docker.sock", *args],
                                capture_output=True, text=True, timeout=120)
        if result.returncode:
            if missing and any(text in result.stderr.lower() for text in ("no such image", "no such object")):
                return None
            raise ValueError("Docker command failed: " + " ".join(args) + ". " + result.stderr.strip())
        return result.stdout.strip()

    def inspect(self, kind, identifiers):
        return json.loads(self.run(kind, "inspect", *identifiers)) if identifiers else []


def image_references(root):
    references = {DEFAULT_AGENT_IMAGE, "borgvr-agent:ci", PYTHON_IMAGE}
    env = root / ".env"
    if env.is_symlink():
        raise ValueError("Refusing to read a symlinked .env")
    if env.exists():
        for line in env.read_text().splitlines():
            key, separator, value = line.partition("=")
            if separator and key in ("BORGVR_AGENT_IMAGE", "BORGVR_VLLM_IMAGE"):
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_./:@+-]{0,511}", value):
                    raise ValueError("Invalid image reference in .env")
                references.add(value)
    return references


def image_repository(reference):
    name = reference.split("@", 1)[0]
    return name.rsplit(":", 1)[0] if name.rfind(":") > name.rfind("/") else name


def docker_plan(root, docker, remove_images):
    docker.run("info")
    ids = docker.run("ps", "-aq", "--filter", f"label={LABEL}={PROJECT}").split()
    containers = docker.inspect("container", ids)
    references = image_references(root)
    for container in containers:
        labels = container["Config"].get("Labels") or {}
        directory = labels.get("com.docker.compose.project.working_dir")
        if labels.get(LABEL) != PROJECT or not directory or Path(directory).resolve() != root.resolve():
            raise ValueError("A BorgVR container belongs to a different deployment directory; nothing was removed")
        references.add(container["Config"]["Image"])
    known_ids = {container["Id"] for container in containers}
    volume_names = docker.run("volume", "ls", "-q", "--filter", f"label={LABEL}={PROJECT}").split()
    volumes = docker.inspect("volume", volume_names)
    for volume in volumes:
        if volume["Name"] != "borgvr-ai_model-cache" or (volume.get("Labels") or {}).get(LABEL) != PROJECT:
            raise ValueError("Unexpected project volume; refusing automatic removal")
        users = docker.run("ps", "-aq", "--no-trunc", "--filter", f"volume={volume['Name']}").split()
        if set(users) - known_ids:
            raise ValueError("The model cache is also used by another container; nothing was removed")
    network_ids = docker.run("network", "ls", "-q", "--filter", f"label={LABEL}={PROJECT}").split()
    networks = docker.inspect("network", network_ids)
    for network in networks:
        if (network.get("Labels") or {}).get(LABEL) != PROJECT or network["Name"] != "borgvr-ai_default":
            raise ValueError("Unexpected project network; refusing automatic removal")
        if set(network.get("Containers") or {}) - known_ids:
            raise ValueError("The BorgVR network is also used by another container; nothing was removed")
    images, retained = set(), set()
    if remove_images:
        # Include old agent versions by our OCI source label, not unrelated vLLM images.
        old_ids = docker.run("image", "ls", "-q", "--no-trunc", "--filter",
                             "label=org.opencontainers.image.source=https://github.com/JensDerKrueger/BorgVR").split()
        if old_ids:
            for image in docker.inspect("image", old_ids):
                references.update(image.get("RepoTags") or [])
                references.update(image.get("RepoDigests") or [])
        repositories = {image_repository(reference) for reference in references}
        for reference in sorted(references):
            info = docker.run("image", "inspect", reference, missing=True)
            if info is None:
                continue
            image = json.loads(info)[0]
            image_id = image["Id"]
            aliases = {reference} | {alias for alias in (image.get("RepoTags") or []) + (image.get("RepoDigests") or [])
                                     if image_repository(alias) in repositories}
            users = docker.run("ps", "-aq", "--no-trunc", "--filter", f"ancestor={image_id}").split()
            if set(users) - known_ids:
                retained.update(aliases)
            else:
                images.update(aliases)
    return {"containers": [c["Id"] for c in containers], "volumes": [v["Name"] for v in volumes],
            "networks": [n["Id"] for n in networks], "images": sorted(images), "shared_images_retained": sorted(retained)}


def checkout_target(root):
    parent = root.parent
    if (parent / ".git").is_dir() and not (parent / ".git").is_symlink():
        def git(*args):
            return subprocess.run(["git", "-c", "safe.directory=" + str(parent.resolve()),
                                   "-c", "core.fsmonitor=false", "-C", str(parent), *args], check=True,
                                  capture_output=True, text=True, timeout=30).stdout.strip()
        if Path(git("rev-parse", "--show-toplevel")).resolve() != parent.resolve():
            raise ValueError("Unexpected Git worktree root")
        if git("remote", "get-url", "origin") not in (
            "https://github.com/JensDerKrueger/BorgVR.git", "git@github.com:JensDerKrueger/BorgVR.git"):
            raise ValueError("Refusing to delete a checkout from a different repository")
        if git("status", "--porcelain", "--untracked-files=all"):
            raise ValueError("Checkout has local changes or untracked files; preserve them before removing it")
        target = parent
    elif root.name in ("borgvr-agent", "BorgVRAgentServer") and (root / "release.json").is_file():
        release = root / "release.json"
        if release.is_symlink() or release.stat().st_size > 65536:
            raise ValueError("Invalid deployment manifest")
        manifest = json.loads(release.read_text())
        if not isinstance(manifest, dict) or manifest.get("repository") != "JensDerKrueger/BorgVR":
            raise ValueError("Deployment bundle belongs to a different repository")
        target = root
    else:
        raise ValueError("Cannot identify a disposable BorgVR clone or deployment bundle")
    import pwd
    protected = {Path(p) for p in ("/", "/home", "/root", "/opt", "/tmp", "/usr", "/usr/local",
                                    "/etc", "/var", "/var/lib", "/srv", "/run", "/bin", "/sbin", "/lib")}
    protected.add(Path.home().resolve())
    protected.update(Path(p.pw_dir).resolve() for p in pwd.getpwall() if p.pw_dir)
    if target.resolve() in protected or len(target.resolve().parts) < 3 or target.is_symlink() or target.is_mount():
        raise ValueError("Refusing to delete a home, system directory, symlink or mount point")
    return target


def remove_local(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        if path.is_mount():
            raise ValueError("Refusing to remove a mounted directory: " + str(path))
        shutil.rmtree(path)


def apply_plan(root, docker, plan, checkout=None):
    # Docker must be cleaned first; leave configuration available if Docker reports a failure.
    if plan["containers"]:
        docker.run("container", "rm", "--force", "--volumes", *plan["containers"])
    for name in plan["volumes"]:
        docker.run("volume", "rm", name)
    for identifier in plan["networks"]:
        docker.run("network", "rm", identifier)
    for reference in plan["images"]:
        docker.run("image", "rm", reference, missing=True)  # Another removed tag may already have released this digest.
    if development_plan(root) is not None:
        from development import cleanup
        cleanup(root)
    remove_rules(root)
    if checkout is not None:
        remove_local(checkout)
    else:
        for name in LOCAL_FILES:
            remove_local(root / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--yes", action="store_true", help="Confirm deletion; default only prints the plan")
    parser.add_argument("--remove-images", action="store_true", help="Also remove configured agent/vLLM/probe image references when unused elsewhere")
    parser.add_argument("--remove-checkout", action="store_true", help="Also delete the clean BorgVR Git clone or extracted deployment bundle")
    parser.add_argument("--files-only", action="store_true", help="Skip Docker checks/removal, e.g. to undo cloning before installing Docker")
    args = parser.parse_args()
    development = development_plan(ROOT)
    if development is not None and args.files_only:
        parser.error("Remove development mode with dev disable --remove first, or use normal uninstall with Docker cleanup")
    if args.files_only and args.remove_images:
        parser.error("--files-only cannot remove Docker images")
    target = checkout_target(ROOT) if args.remove_checkout else None
    docker = Docker()
    plan = {key: [] for key in ("containers", "volumes", "networks", "images", "shared_images_retained")}
    if not args.files_only:
        if not shutil.which("docker"):
            parser.error("Docker is unavailable; use --files-only explicitly if only files should be removed")
        plan = docker_plan(ROOT, docker, args.remove_images)
    print(json.dumps({**plan, "local_paths": [str(target)] if target else [str(ROOT / name) for name in LOCAL_FILES],
                      "firewall_rules": load_rules(ROOT), "development": development,
                      "docker_skipped": args.files_only}, indent=2))
    if not args.yes:
        print("Preview only. Add --yes to delete the listed resources. Keys/certificates will be lost; Docker/model data is skipped with --files-only.")
        return
    apply_plan(ROOT, docker, plan, target)
    print("Listed BorgVR resources removed. Shared image references, Docker Engine and system packages were not removed.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error
