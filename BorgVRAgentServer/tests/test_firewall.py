from pathlib import Path
import shlex
import subprocess

import pytest

import firewall


class Host:
    def __init__(self):
        self.tools = {"ufw", "firewall-cmd"}
        self.ufw = "Status: active"
        self.firewalld = "not running"
        self.ufw_entries = []
        self.rich_entries = set()
        self.calls = []
        self.fail_add = False

    def run(self, *args, codes=(0,)):
        self.calls.append(args)
        if args == ("ufw", "status"):
            return subprocess.CompletedProcess(args, 0, self.ufw, "")
        if args == ("ufw", "show", "added"):
            return subprocess.CompletedProcess(args, 0, "\n".join("ufw " + shlex.join(tokens) for tokens in self.ufw_entries), "")
        if args[:2] == ("ufw", "--force"):
            tokens = list(args[2:])
            if tokens[0] == "delete":
                self.ufw_entries.remove(tokens[1:])
            elif self.fail_add:
                raise ValueError("UFW failed")
            else:
                self.ufw_entries.append(tokens)
            return subprocess.CompletedProcess(args, 0, "Rule updated", "")
        if args == ("firewall-cmd", "--state"):
            return subprocess.CompletedProcess(args, 0 if self.firewalld == "running" else 252, self.firewalld, "")
        if args == ("firewall-cmd", "--get-default-zone"):
            return subprocess.CompletedProcess(args, 0, "public\n", "")
        if args == ("firewall-cmd", "--get-zones"):
            return subprocess.CompletedProcess(args, 0, "public internal docker", "")
        if args[0] == "firewall-cmd":
            zone = next(value for value in args if value.startswith("--zone="))
            action = args[-1].split("-rich-rule=", 1)
            key = ("--permanent" in args, zone, action[1])
            if action[0] == "--query":
                present = key in self.rich_entries
                return subprocess.CompletedProcess(args, 0 if present else 1, "yes" if present else "no", "")
            if action[0] == "--add":
                if self.fail_add and not key[0]:
                    raise ValueError("Runtime firewall update failed")
                self.rich_entries.add(key)
            elif action[0] == "--remove":
                self.rich_entries.remove(key)
            else:
                raise AssertionError(args)
            return subprocess.CompletedProcess(args, 0, "success", "")
        raise AssertionError(args)

    @property
    def changes(self):
        return [args for args in self.calls if args[:2] == ("ufw", "--force") or
                any(value.startswith(("--add-", "--remove-")) for value in args)]


@pytest.fixture
def host(tmp_path, monkeypatch):
    fake = Host()
    (tmp_path / "runtime").mkdir(mode=0o700)
    (tmp_path / ".env").write_text("BORGVR_BIND_ADDRESS=134.91.11.251\nBORGVR_PORT=9876\n")
    monkeypatch.setattr(firewall.platform, "system", lambda: "Linux")
    monkeypatch.setattr(firewall.os, "geteuid", lambda: 0)
    monkeypatch.setattr(firewall.shutil, "which", lambda name: "/fake/" + name if name in fake.tools else None)
    monkeypatch.setattr(firewall, "run", fake.run)
    monkeypatch.setattr(firewall, "prepare_runtime_access", lambda root: None)
    return fake


def test_default_only_inspects_and_warns_about_docker_and_upstream_firewalls(tmp_path, host, capsys):
    firewall.check(tmp_path)
    assert not host.changes and not (tmp_path / "runtime" / firewall.STATE).exists()
    output = capsys.readouterr().out
    assert "ufw" in output and "bypass" in output and "institutional" in output and "--open-firewall" in output


def test_ufw_opt_in_uses_configured_endpoint_and_tracks_only_new_rule(tmp_path, host):
    host.ufw_entries.append(["allow", "22/tcp", "comment", "existing SSH"])
    original = host.ufw_entries.copy()
    firewall.check(tmp_path, opening=True)
    assert len(host.changes) == 1
    assert host.changes[0][:4] == ("ufw", "--force", "allow", "proto")
    assert "9876" in host.changes[0] and "134.91.11.251" in host.changes[0]
    assert "0.0.0.0/0" in host.changes[0]  # IPv4 only, including wildcard binds.
    entries = firewall.load_rules(tmp_path)
    assert len(entries) == 1 and entries[0]["port"] == 9876
    assert (tmp_path / "runtime" / firewall.STATE).stat().st_mode & 0o777 == 0o600
    firewall.check(tmp_path, opening=True)
    assert len(host.changes) == 1
    firewall.remove_rules(tmp_path)
    assert host.ufw_entries == original and firewall.load_rules(tmp_path) == []


@pytest.mark.parametrize("rule", [
    "allow proto tcp from any to 134.91.11.251 port 9876",
    "allow in from 0.0.0.0/0 to 134.91.11.251/32 port 9876 proto tcp comment 'existing owner'",
])
def test_preexisting_ufw_rule_is_neither_changed_nor_claimed(tmp_path, host, rule):
    host.ufw_entries.append(shlex.split(rule))
    firewall.check(tmp_path, opening=True)
    assert not host.changes and firewall.load_rules(tmp_path) == []
    firewall.remove_rules(tmp_path)
    assert len(host.ufw_entries) == 1


def test_modified_ufw_rule_is_no_longer_owned(tmp_path, host):
    firewall.check(tmp_path, opening=True)
    host.ufw_entries[0][-1] = "Administrator replaced this rule"
    count = len(host.calls)
    firewall.remove_rules(tmp_path)
    assert len(host.ufw_entries) == 1 and not any("delete" in args for args in host.calls[count:])


def test_firewalld_adds_permanent_and_runtime_rule_without_global_reload(tmp_path, host):
    host.ufw, host.firewalld = "Status: inactive", "running"
    firewall.check(tmp_path, opening=True, zone="internal")
    assert len(host.rich_entries) == 2 and len(firewall.load_rules(tmp_path)) == 2
    assert all("--zone=internal" in args for args in host.changes)
    assert all('family="ipv4"' in args[-1] and 'port="9876"' in args[-1] for args in host.changes)
    assert not any("--reload" in args or "--runtime-to-permanent" in args for args in host.calls)
    firewall.remove_rules(tmp_path)
    assert host.rich_entries == set()


def test_firewalld_preserves_preexisting_runtime_rule(tmp_path, host):
    host.ufw, host.firewalld = "Status: inactive", "running"
    rule = 'rule family="ipv4" destination address="134.91.11.251" port port="9876" protocol="tcp" accept'
    original = (False, "--zone=public", rule)
    host.rich_entries.add(original)
    firewall.check(tmp_path, opening=True)
    assert len(firewall.load_rules(tmp_path)) == 1
    firewall.remove_rules(tmp_path)
    assert host.rich_entries == {original}


def test_partial_firewalld_failure_retains_cleanup_record(tmp_path, host):
    host.ufw, host.firewalld, host.fail_add = "Status: inactive", "running", True
    with pytest.raises(ValueError, match="Runtime firewall"):
        firewall.check(tmp_path, opening=True)
    assert len(host.rich_entries) == len(firewall.load_rules(tmp_path)) == 1
    firewall.remove_rules(tmp_path)
    assert not host.rich_entries


def test_failed_ufw_change_does_not_claim_a_rule(tmp_path, host):
    host.fail_add = True
    with pytest.raises(ValueError, match="UFW failed"):
        firewall.check(tmp_path, opening=True)
    assert not host.ufw_entries and not firewall.load_rules(tmp_path)


def test_failure_to_save_rule_record_rolls_back_only_new_rule(tmp_path, host, monkeypatch):
    original = ["allow", "22/tcp", "comment", "SSH"]
    host.ufw_entries.append(original)
    def fail(*args):
        raise OSError("Disk full")
    monkeypatch.setattr(firewall, "save_rules", fail)
    with pytest.raises(OSError, match="Disk full"):
        firewall.check(tmp_path, opening=True)
    assert host.ufw_entries == [original]


def test_wildcard_bind_adds_only_ipv4_rule(tmp_path, host):
    (tmp_path / ".env").write_text("BORGVR_BIND_ADDRESS=0.0.0.0\nBORGVR_PORT=8766\n")
    firewall.check(tmp_path, opening=True)
    args = host.changes[0]
    assert args[args.index("from") + 1] == "0.0.0.0/0" and args[args.index("to") + 1] == "any"
    assert len(host.ufw_entries) == 1


@pytest.mark.parametrize("ufw,firewalld", [("unknown", "not running"), ("Status: active", "running"), ("", "not running")])
def test_uncertain_or_multiple_managers_refuse_changes(tmp_path, host, ufw, firewalld):
    host.ufw, host.firewalld = ufw, firewalld
    with pytest.raises(ValueError):
        firewall.check(tmp_path, opening=True)
    assert not host.changes


def test_inactive_firewalls_are_never_enabled_or_installed(tmp_path, host, capsys):
    host.ufw, host.firewalld = "Status: inactive", "not running"
    firewall.check(tmp_path, opening=True)
    assert not host.changes
    assert "Custom nftables/iptables" in capsys.readouterr().out


@pytest.mark.parametrize("bind,port", [("bad", "8766"), ("127.0.0.1", "8766"), ("0.0.0.0", "22"),
                                      ("134.91.11.251", "8766; touch unsafe")])
def test_invalid_or_loopback_endpoint_never_changes_firewall(tmp_path, host, bind, port):
    (tmp_path / ".env").write_text(f"BORGVR_BIND_ADDRESS={bind}\nBORGVR_PORT={port}\n")
    with pytest.raises(ValueError):
        firewall.check(tmp_path, opening=True)
    assert not host.changes


def test_opt_in_requires_root(tmp_path, host, monkeypatch):
    monkeypatch.setattr(firewall.os, "geteuid", lambda: 1000)
    with pytest.raises(ValueError, match="sudo"):
        firewall.check(tmp_path, opening=True)
    assert not host.changes


@pytest.mark.parametrize("zone", ["../../etc", "public; reboot", "--panic-on", "", "x\ninternal"])
def test_invalid_zone_rejected(zone):
    with pytest.raises(ValueError):
        firewall.zone_name(zone)


def test_wrong_zone_and_zone_with_ufw_refuse_changes(tmp_path, host):
    with pytest.raises(ValueError, match="only to firewalld"):
        firewall.check(tmp_path, opening=True, zone="internal")
    host.ufw, host.firewalld = "Status: inactive", "running"
    with pytest.raises(ValueError, match="Unknown firewalld zone"):
        firewall.check(tmp_path, opening=True, zone="missing")
    assert not host.changes


@pytest.mark.parametrize("contents", ["{}", "[]" * 40000,
    '[{"manager":"shell","bind":"0.0.0.0","port":8766,"zone":null,"permanent":true}]'])
def test_corrupt_or_oversize_journal_fails_before_changes(tmp_path, host, contents):
    (tmp_path / "runtime" / firewall.STATE).write_text(contents)
    with pytest.raises(ValueError):
        firewall.check(tmp_path, opening=True)
    assert not host.changes


def test_journal_symlink_does_not_modify_target(tmp_path, host):
    outside = tmp_path / "outside"
    outside.write_text("[]")
    (tmp_path / "runtime" / firewall.STATE).symlink_to(outside)
    with pytest.raises(OSError):
        firewall.check(tmp_path, opening=True)
    assert outside.read_text() == "[]" and not host.changes


def test_external_commands_have_timeout_and_no_shell(monkeypatch):
    def execute(args, **kwargs):
        assert args == ("ufw", "status") and kwargs["timeout"] == 20
        assert kwargs["env"]["LC_ALL"] == "C" and "shell" not in kwargs
        raise subprocess.TimeoutExpired(args, 20)
    monkeypatch.setattr(firewall.subprocess, "run", execute)
    with pytest.raises(subprocess.TimeoutExpired):
        firewall.run("ufw", "status")


@pytest.mark.parametrize("args", [("status", "--open-firewall"), ("init", "--open-firewall"),
                                  ("install", "--firewall-zone", "public"),
                                  ("start", "--open-firewall", "--firewall-zone", "../../etc")])
def test_invalid_setup_flag_combinations_fail_before_side_effects(args):
    script = Path(__file__).resolve().parents[1] / "setup.sh"
    result = subprocess.run(["bash", str(script), *args], capture_output=True, text=True)
    assert result.returncode == 1 and "firewall" in result.stderr.lower()
