"""Inspect host firewall managers; only change the agent port with explicit consent."""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import tempfile

from configure import ROOT, prepare_runtime_access, read_configuration

STATE = "firewall-rules.json"
NOTICE = ("Docker-published ports can bypass UFW or firewalld host-input rules. This is a port "
          "exception, NOT a source-IP restriction or proof of remote reachability. Router, VPN, "
          "provider and institutional firewalls must be checked separately.")


def run(*args, codes=(0,)):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20,
                            env={**os.environ, "LC_ALL": "C", "LANG": "C"})
    if result.returncode not in codes:
        raise ValueError("Firewall command failed: " + shlex.join(args) + ". " + result.stderr.strip()[:1024])
    return result


def endpoint(bind, port):
    if not isinstance(bind, str) or isinstance(port, bool):
        raise ValueError("Expected an IPv4 address and a numeric agent port")
    address = ipaddress.IPv4Address(bind)
    if address.is_multicast or not re.fullmatch(r"[0-9]{1,5}", str(port)) or not 1024 <= int(port) <= 65535:
        raise ValueError("Expected an IPv4 bind address and an agent port from 1024 to 65535")
    return str(address), int(port)


def zone_name(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", value):
        raise ValueError("Invalid firewalld zone")
    return value


def validate_entry(entry):
    if not isinstance(entry, dict) or set(entry) != {"manager", "bind", "port", "zone", "permanent"}:
        raise ValueError("Invalid recorded firewall rule")
    bind, port = endpoint(entry["bind"], entry["port"])
    if bind != entry["bind"] or type(entry["port"]) is not int or type(entry["permanent"]) is not bool:
        raise ValueError("Invalid recorded firewall endpoint")
    if entry["manager"] == "ufw":
        if entry["zone"] is not None or not entry["permanent"]:
            raise ValueError("Invalid recorded UFW rule")
    elif entry["manager"] == "firewalld":
        zone_name(entry["zone"])
    else:
        raise ValueError("Unknown recorded firewall manager")
    return entry


def load_rules(root):
    runtime = root / "runtime"
    if runtime.is_symlink():
        raise ValueError("Refusing a symlinked runtime directory")
    path = runtime / STATE
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return []
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError("Firewall state must be a regular, single-link file")
        data = handle.read(65537)
    if len(data) > 65536:
        raise ValueError("Firewall state is too large")
    entries = json.loads(data)
    if not isinstance(entries, list) or len(entries) > 64:
        raise ValueError("Invalid firewall state")
    return [validate_entry(entry) for entry in entries]


def save_rules(root, entries):
    runtime = root / "runtime"
    if runtime.is_symlink() or not runtime.is_dir() or len(entries) > 64:
        raise ValueError("Expected a private runtime directory and at most 64 firewall rules")
    for entry in entries:
        validate_entry(entry)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", dir=runtime, prefix=".firewall-", delete=False) as handle:
            temporary = Path(handle.name)
            json.dump(entries, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, runtime / STATE)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def detect():
    active, uncertain = [], []
    for name, command, positive, negative in (
        ("ufw", ("ufw", "status"), "Status: active", "Status: inactive"),
        ("firewalld", ("firewall-cmd", "--state"), "running", "not running"),
    ):
        if not shutil.which(command[0]):
            continue
        try:
            result = run(*command, codes=(0, 1, 252))
            output = (result.stdout + "\n" + result.stderr).strip()
            if result.returncode == 0 and output.splitlines()[:1] == [positive]:
                active.append(name)
            elif output != negative:
                uncertain.append(name)
        except (OSError, ValueError, subprocess.SubprocessError):
            uncertain.append(name)
    return active, uncertain


def ufw_marker(entry):
    return f"BorgVR-agent-{entry['bind']}-{entry['port']}"


def ufw_rules():
    return [shlex.split(line)[1:] for line in run("ufw", "show", "added").stdout.splitlines()
            if line.startswith("ufw ")]


def ufw_matches(tokens, entry):
    tokens = tokens[:tokens.index("comment")] if "comment" in tokens else tokens
    if not tokens or tokens[0] != "allow":
        return False
    tokens = tokens[1:]
    if tokens[:1] == ["in"]:
        tokens = tokens[1:]
    target = "any" if entry["bind"] == "0.0.0.0" else entry["bind"]
    if target == "any" and tokens == [f"{entry['port']}/tcp"]:
        return True
    values, side = {}, "to"
    while tokens:
        if len(tokens) < 2 or tokens[0] not in ("proto", "from", "to", "port") or tokens[0] in values:
            return False
        key, value, *tokens = tokens
        if key in ("from", "to"):
            side = key
        if key == "port" and side == "from":
            return False
        values[key] = value
    values = {"from": "any", "to": "any", **values}
    for key in ("from", "to"):
        try:
            network = ipaddress.IPv4Network(values[key], strict=False)
        except ValueError:
            continue
        values[key] = "any" if network.prefixlen == 0 else str(network.network_address) if network.prefixlen == 32 else str(network)
    return values == {
        "from": "any", "to": target, "proto": "tcp", "port": str(entry["port"])}


def rich_rule(entry):
    destination = f' destination address="{entry["bind"]}"' if entry["bind"] != "0.0.0.0" else ""
    return f'rule family="ipv4"{destination} port port="{entry["port"]}" protocol="tcp" accept'


def firewalld_rule(entry, action):
    return ("firewall-cmd", *(["--permanent"] if entry["permanent"] else []),
            "--zone=" + entry["zone"], f"--{action}-rich-rule=" + rich_rule(entry))


def rule_present(entry, owned=False):
    if entry["manager"] == "ufw":
        return any(ufw_matches(tokens, entry) and (not owned or tokens[-2:] == ["comment", ufw_marker(entry)])
                   for tokens in ufw_rules())
    result = run(*firewalld_rule(entry, "query"), codes=(0, 1))
    if result.stdout.strip() not in ("yes", "no"):
        raise ValueError("Unexpected firewalld query response")
    return result.returncode == 0


def change_rule(entry, remove=False):
    if entry["manager"] == "ufw":
        target = "any" if entry["bind"] == "0.0.0.0" else entry["bind"]
        run("ufw", *(["delete"] if remove else []), "allow", "proto", "tcp", "from", "0.0.0.0/0", "to", target,
            "port", str(entry["port"]), "comment", ufw_marker(entry))
    else:
        run(*firewalld_rule(entry, "remove" if remove else "add"))


def remove_rules(root):
    entries = load_rules(root)
    if not entries:
        return
    if os.geteuid() != 0 or platform.system() != "Linux":
        raise ValueError("Removing recorded host firewall rules requires sudo on Linux")
    for entry in entries.copy():
        if rule_present(entry, owned=True):
            change_rule(entry, remove=True)
        entries.remove(entry)
        save_rules(root, entries)


def check(root, opening=False, zone=None):
    config = read_configuration(root)
    bind, port = endpoint(config["BORGVR_BIND_ADDRESS"], config["BORGVR_PORT"])
    if platform.system() != "Linux":
        if opening:
            raise ValueError("Automatic firewall configuration requires Linux")
        print("Host firewall inspection is available on Linux only; no firewall was changed.")
        return
    if opening and os.geteuid() != 0:
        raise ValueError("Use sudo for --open-firewall")
    active, uncertain = detect()
    print("Active supported host firewalls: " + (", ".join(active) or "none detected") + ".")
    print(NOTICE)
    if uncertain:
        message = "Could not reliably inspect: " + ", ".join(uncertain)
        if opening:
            raise ValueError(message + "; no firewall rules changed")
        print(message + ". Run setup with sudo to inspect the host firewall.")
    if not opening:
        print(f"No firewall rules changed. To request TCP {port}, explicitly use --open-firewall with install/start/restart/update.")
        return
    if uncertain or len(active) > 1:
        raise ValueError("Multiple or uncertain firewall managers; configure the agent port manually")
    if not active:
        print("No active supported firewall to modify. Custom nftables/iptables rules may still filter traffic; they are not changed.")
        return
    if ipaddress.ip_address(bind).is_loopback:
        raise ValueError("The agent is bound to loopback; configure --bind with a reachable server address before opening a firewall")
    manager = active[0]
    if zone is not None and manager != "firewalld":
        raise ValueError("--firewall-zone applies only to firewalld")
    entries = load_rules(root)
    base = {"manager": manager, "bind": bind, "port": port, "zone": None, "permanent": True}
    if manager == "firewalld":
        base["zone"] = zone_name(zone or run("firewall-cmd", "--get-default-zone").stdout.strip())
        zones = run("firewall-cmd", "--get-zones").stdout.split()
        if base["zone"] not in zones:
            raise ValueError("Unknown firewalld zone")
        print("Using firewalld zone " + base["zone"] + "; verify that your client-facing interface/source belongs to this zone.")
        planned = [{**base, "permanent": permanent} for permanent in (True, False)]
    else:
        planned = [base]
    for entry in planned:
        if rule_present(entry):
            print("Requested firewall rule already exists; unchanged.")
            continue
        if len(entries) >= 64:
            raise ValueError("Too many recorded BorgVR firewall rules")
        change_rule(entry)
        updated = entries if entry in entries else [*entries, entry]
        try:
            save_rules(root, updated)
        except Exception:
            if rule_present(entry, owned=True):
                change_rule(entry, remove=True)
            raise
        entries = updated
        if not rule_present(entry, owned=True):
            raise ValueError("Could not verify the added firewall rule; its cleanup is recorded in runtime/" + STATE)
    prepare_runtime_access(root)
    print(f"Requested IPv4 TCP {port} exception for {bind} is configured in {manager}; no global reload, firewall enable or policy change was performed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--open", action="store_true", help="Explicitly allow the configured agent TCP port")
    parser.add_argument("--zone", type=zone_name)
    args = parser.parse_args()
    check(ROOT, args.open, args.zone)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error)) from error
