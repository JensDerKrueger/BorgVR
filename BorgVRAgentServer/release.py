"""Build artifacts and explicitly publish an already tested image; never change visibility."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent
ARCHIVE = "borgvr-agent-linux-amd64.tar.gz"
BUNDLE = "borgvr-agent-deployment.tar.gz"
LOCAL_IMAGE = "borgvr-agent:ci"
DEPLOYMENT_FILES = (
    "compose.yaml", "compose.cuda.yaml", "compose.rocm.yaml", "configure.py", "model_config.py",
    "setup.sh", "setup-host.sh", "uninstall.py", "vllm_start.py",
    "README.md", "README.de.md", "PROTOCOL.md", "LICENSE",
)
VERSION = r"[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?"
DIGEST = r"sha256:[0-9a-f]{64}"


def metadata(repository, commit, version="", publish=False, ref=""):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a complete source commit SHA")
    if version and (len(version) > 64 or not re.fullmatch(VERSION, version)):
        raise ValueError("Use a version such as 3.9.0, not latest/edge or shell syntax")
    if publish and (ref != "refs/heads/main" or not version):
        raise ValueError("Publishing requires the main branch and an explicit version")
    return {"repository": repository, "commit": commit,
            "image": f"ghcr.io/{repository.split('/')[0].lower()}/borgvr-agent",
            "version": version or f"dev-{commit[:12]}", "platform": "linux/amd64"}


def from_environment():
    return metadata(os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"],
                    os.environ.get("AGENT_VERSION", ""), os.environ.get("AGENT_PUBLISH") == "true",
                    os.environ.get("GITHUB_REF", ""))


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def command(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def checksums(output, include_image):
    names = [BUNDLE, "release.json"] + ([ARCHIVE] if include_image else [])
    (output / "SHA256SUMS").write_text("".join(f"{digest(output / name)}  {name}\n" for name in names))


def write_bundle(output, info):
    (output / "release.json").write_text(json.dumps(info, indent=2) + "\n")
    image = info["image_reference"]
    start = "" if info["published"] else f"sudo docker load --input {ARCHIVE}\n"
    install = (
        "# BorgVR Agent Deployment\n\n"
        f"Source commit: `{info['commit']}`. Platform: `{info['platform']}`.\n\n"
        "Prepare Docker and the CUDA/ROCm prerequisites once using the reviewed setup-host.sh as administrator.\n"
        "Use one administrator account with sudo for all setup and operations:\n\n"
        f"```\n{start}sudo ./setup.sh install --host YOUR-SERVER-NAME --bind YOUR-SERVER-IP --agent-image {image}\nsudo ./setup.sh test\n```\n\n"
        "Replace the example host/IP. Configure a trusted TLS certificate for production.\n"
        "For AMD add --backend rocm; see the guides for supported GPU/model combinations.\n"
        "Install downloads missing images and starts/tests both containers; private images require registry login.\n"
        "Re-running install recreates BorgVR containers without deleting model volumes or images.\n"
        "When already root, omit sudo. The agent container remains unprivileged.\n"
        "Ordinary BorgVR users need no Docker or root access. No native voice client or H200 inference\n"
        "test is included in this CPU-only build. See README.md and README.de.md for details.\n"
    )
    with tarfile.open(output / BUNDLE, "w:gz") as archive:
        files = []
        for name in DEPLOYMENT_FILES:
            path = ROOT / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("Deployment files must be regular files")
            files.append((name, path.read_bytes()))
        for name, data in (*files, ("release.json", (output / "release.json").read_bytes()),
                           ("INSTALL.md", install.encode())):
            entry = tarfile.TarInfo("borgvr-agent/" + name)
            entry.mode = 0o755 if name.endswith(".sh") or name == "uninstall.py" else 0o644
            entry.size = len(data)
            archive.addfile(entry, io.BytesIO(data))
    checksums(output, include_image=not info["published"])


def prepare_bundle(output, info, image_id):
    if not re.fullmatch(DIGEST, image_id):
        raise ValueError("Invalid Docker image ID")
    info = {**info, "image_id": image_id, "archive_sha256": digest(output / ARCHIVE),
            "image_reference": LOCAL_IMAGE, "published": False}
    write_bundle(output, info)
    return info


def verify(output, repository, commit, load=False):
    text = (output / "release.json").read_bytes()
    if len(text) > 65536:
        raise ValueError("Oversized release manifest")
    info = json.loads(text)
    expected = metadata(repository, commit)
    if any(info[key] != expected[key] for key in ("repository", "commit", "image", "platform")):
        raise ValueError("Artifact does not belong to this source commit/repository")
    if info.get("published") is not False or info.get("image_reference") != LOCAL_IMAGE:
        raise ValueError("Expected an unpublished build artifact")
    if not re.fullmatch(DIGEST, info["image_id"]):
        raise ValueError("Invalid image ID")
    expected_names = {ARCHIVE, BUNDLE, "release.json"}
    seen = set()
    for line in (output / "SHA256SUMS").read_text().splitlines():
        sha, name = line.split("  ", 1)
        if name not in expected_names or name in seen or sha != digest(output / name):
            raise ValueError("Artifact checksum mismatch")
        seen.add(name)
    if seen != expected_names or digest(output / ARCHIVE) != info["archive_sha256"]:
        raise ValueError("Incomplete or modified image archive")
    if load:
        command("docker", "load", "--input", str(output / ARCHIVE))
        if command("docker", "image", "inspect", "--format", "{{.Id}}", LOCAL_IMAGE) != info["image_id"]:
            raise ValueError("Loaded image differs from the tested image")
    return info


def publish(output):
    expected = from_environment()  # Main branch and version gate also applies outside Actions.
    if os.environ.get("AGENT_PUBLISH") != "true":
        raise ValueError("Publication was not explicitly enabled")
    info = verify(output, expected["repository"], expected["commit"])
    if info["version"] != expected["version"]:
        raise ValueError("Version does not match the tested build")
    if command("docker", "image", "inspect", "--format", "{{.Id}}", LOCAL_IMAGE) != info["image_id"]:
        raise ValueError("The tested image must be loaded before publication")
    sha_tag = f"{info['image']}:sha-{info['commit']}"
    command("docker", "tag", LOCAL_IMAGE, sha_tag)
    command("docker", "push", sha_tag)
    version_tag = f"{info['image']}:{info['version']}"
    existing = subprocess.run(["docker", "manifest", "inspect", version_tag], capture_output=True, text=True)
    if existing.returncode == 0:
        if json.loads(existing.stdout).get("config", {}).get("digest") != info["image_id"]:
            raise ValueError("Version already points to a different image; choose a new version")
    elif not any(term in existing.stderr.lower() for term in ("manifest unknown", "no such manifest", "not found")):
        raise ValueError("Cannot safely determine whether the version already exists")
    command("docker", "tag", LOCAL_IMAGE, version_tag)
    command("docker", "push", version_tag)
    manifest = json.loads(command("docker", "image", "inspect", "--format", "{{json .RepoDigests}}", version_tag))
    reference = next(value for value in manifest if value.startswith(info["image"] + "@sha256:"))
    if not re.fullmatch(re.escape(info["image"]) + "@" + DIGEST, reference):
        raise ValueError("Invalid registry digest")
    info.update(image_reference=reference, published=True)
    write_bundle(output, info)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as stream:
            stream.write(f"## Published tested image\n\n`{reference}`\n\n"
                         "The deployment artifact pins this digest. Package visibility was not changed.\n")
    print(reference)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("metadata")
    bundle = sub.add_parser("bundle")
    bundle.add_argument("--output", type=Path, required=True)
    bundle.add_argument("--image-id", required=True)
    check = sub.add_parser("verify")
    check.add_argument("--output", type=Path, required=True)
    check.add_argument("--load", action="store_true")
    push = sub.add_parser("publish")
    push.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "metadata":
        info = from_environment()
        if path := os.environ.get("GITHUB_OUTPUT"):
            with open(path, "a") as stream:
                for key in ("image", "version"):
                    stream.write(f"{key}={info[key]}\n")
        print(json.dumps(info))
    elif args.action == "bundle":
        prepare_bundle(args.output, from_environment(), args.image_id)
    elif args.action == "verify":
        verify(args.output, os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"], args.load)
    else:
        publish(args.output)


if __name__ == "__main__":
    main()
