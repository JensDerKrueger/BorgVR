"""Profile-bound persistence for the opt-in workflow service."""

import argparse
from contextlib import contextmanager
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
from uuid import uuid4

from .learner_state import hypotheses_for, portable_state
from .workflow_learner import MAX_EPISODES, Episode, find_patterns


SCHEMA = """
CREATE TABLE IF NOT EXISTS profiles (
    id TEXT PRIMARY KEY, corpus TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY, profile TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    token_hash BLOB NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS episodes (
    profile TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    id TEXT NOT NULL, payload TEXT NOT NULL,
    PRIMARY KEY (profile, id)
);
CREATE TABLE IF NOT EXISTS jobs (
    profile TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    id TEXT NOT NULL, report TEXT,
    queued INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS workflow_states (
    profile TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
    job_id TEXT NOT NULL,
    hypotheses TEXT NOT NULL
);
"""

PROFILE_LIMIT = 64
DEVICE_LIMIT = 16
TOKEN_PATTERN = re.compile(r"Bearer (wv1_[0-9a-f]{64})")


class WorkflowError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code
        super().__init__(code)


class WorkflowStore:
    def __init__(self, path: Path):
        if path.is_symlink():
            raise ValueError("Workflow database must not be a symlink")
        parent = path.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError("Workflow directory must be private and owned by the service user")
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(fd)
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Workflow database must be a private, service-owned regular file")
        self.path = path
        with self.connection() as db:
            db.executescript(SCHEMA)

    @contextmanager
    def connection(self, write=False):
        db = sqlite3.connect(self.path, timeout=2, isolation_level=None)
        try:
            db.execute("PRAGMA foreign_keys=ON")
            db.execute("PRAGMA secure_delete=ON")
            db.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield db
            db.commit()
        except BaseException:
            db.rollback()
            raise
        finally:
            db.close()

    @staticmethod
    def _digest(token):
        return hashlib.sha256(token.encode("ascii")).digest()

    def _insert_device(self, db, profile):
        if db.execute("SELECT COUNT(*) FROM devices WHERE profile=?", (profile,)).fetchone()[0] >= DEVICE_LIMIT:
            raise WorkflowError(409, "device_limit")
        token, device = "wv1_" + secrets.token_hex(32), str(uuid4())
        db.execute("INSERT INTO devices VALUES (?, ?, ?)", (device, profile, self._digest(token)))
        return {"profile_id": profile, "device_id": device, "token": token}

    def create_profile(self):
        profile = str(uuid4())
        with self.connection(write=True) as db:
            if db.execute("SELECT COUNT(*) FROM profiles").fetchone()[0] >= PROFILE_LIMIT:
                raise WorkflowError(409, "profile_limit")
            db.execute("INSERT INTO profiles VALUES (?, ?)", (profile, str(uuid4())))
            return self._insert_device(db, profile)

    def add_device(self, profile):
        with self.connection(write=True) as db:
            if db.execute("SELECT 1 FROM profiles WHERE id=?", (profile,)).fetchone() is None:
                raise WorkflowError(404, "profile_not_found")
            return self._insert_device(db, profile)

    def revoke_device(self, profile, device):
        with self.connection(write=True) as db:
            return db.execute("DELETE FROM devices WHERE id=? AND profile=?", (device, profile)).rowcount == 1

    def delete_profile(self, profile):
        with self.connection(write=True) as db:
            return db.execute("DELETE FROM profiles WHERE id=?", (profile,)).rowcount == 1

    @staticmethod
    def _identity(db, digest):
        if digest is None:
            raise WorkflowError(401, "unauthorized")
        row = db.execute(
            "SELECT p.id, d.id, p.corpus FROM devices d JOIN profiles p ON d.profile=p.id WHERE d.token_hash=?",
            (digest,),
        ).fetchone()
        if row is None:
            raise WorkflowError(401, "unauthorized")
        return row

    def authenticate(self, authorization):
        match = TOKEN_PATTERN.fullmatch(authorization or "")
        digest = self._digest(match[1]) if match else None
        with self.connection() as db:
            self._identity(db, digest)
        return digest

    def profile(self, digest):
        with self.connection() as db:
            profile, device, corpus = self._identity(db, digest)
            return {"profile_id": profile, "device_id": device, "corpus_id": corpus}

    def upload(self, digest, expected_corpus, episode: Episode):
        return self.merge(digest, expected_corpus, [episode]) == 1

    @staticmethod
    def _episode_row(episode):
        data = asdict(episode)
        if episode.evidence is None:
            data.pop("evidence")  # Preserve the canonical v1 payload for existing retries.
        return json.dumps(data, sort_keys=episode.evidence is not None, separators=(",", ":"))

    @staticmethod
    def _episode_value(raw):
        data = json.loads(raw)
        data["actions"] = tuple(data["actions"])
        return Episode(**data)

    def merge(self, digest, expected_corpus, episodes):
        with self.connection(write=True) as db:
            profile, _, corpus = self._identity(db, digest)
            if expected_corpus != corpus:
                raise WorkflowError(409, "corpus_changed")
            rows = dict(db.execute("SELECT id, payload FROM episodes WHERE profile=?", (profile,)))
            additions = {}
            for episode in episodes:
                existing = rows.get(episode.id, additions.get(episode.id))
                if existing is not None:
                    if self._episode_value(existing) != episode:
                        raise WorkflowError(409, "episode_conflict")
                else:
                    additions[episode.id] = self._episode_row(episode)
            if not additions:
                return 0
            if len(rows) + len(additions) > MAX_EPISODES:
                raise WorkflowError(409, "episode_limit")
            db.executemany("INSERT INTO episodes VALUES (?, ?, ?)",
                           ((profile, identifier, payload) for identifier, payload in additions.items()))
            db.execute(
                "INSERT INTO jobs VALUES (?, ?, NULL, unixepoch()) "
                "ON CONFLICT(profile) DO UPDATE SET id=excluded.id, report=NULL, queued=excluded.queued",
                (profile, str(uuid4())),
            )
        return len(additions)

    def state(self, digest):
        with self.connection() as db:
            profile, _, corpus = self._identity(db, digest)
            job = db.execute("SELECT id, report FROM jobs WHERE profile=?", (profile,)).fetchone()
            result = {"corpus_id": corpus}
            if job is None:
                return {**result, "status": "empty", "state": portable_state([], [])}
            if job[1] is None:
                return {**result, "status": "queued", "job_id": job[0]}
            rows = db.execute("SELECT payload FROM episodes WHERE profile=? ORDER BY id", (profile,))
            episodes = [self._episode_value(raw) for raw, in rows]
            checkpoint = db.execute("SELECT hypotheses FROM workflow_states WHERE profile=? AND job_id=?",
                                    (profile, job[0])).fetchone()
            hypotheses = json.loads(checkpoint[0]) if checkpoint else hypotheses_for(episodes)
            return {**result, "status": "ready", "job_id": job[0],
                    "state": portable_state(episodes, hypotheses)}

    def report(self, digest):
        with self.connection() as db:
            profile, _, corpus = self._identity(db, digest)
            row = db.execute("SELECT id, report FROM jobs WHERE profile=?", (profile,)).fetchone()
            if not row:
                return {"status": "empty", "corpus_id": corpus}
            job, report = row
            value = {"status": "queued" if report is None else "ready", "corpus_id": corpus, "job_id": job}
            if report is not None:
                value["report"] = json.loads(report)
            return value

    def clear(self, digest, expected_corpus):
        with self.connection(write=True) as db:
            profile, _, corpus = self._identity(db, digest)
            if expected_corpus != corpus:
                raise WorkflowError(409, "corpus_changed")
            replacement = str(uuid4())
            db.execute("UPDATE profiles SET corpus=? WHERE id=?", (replacement, profile))
            db.execute("DELETE FROM jobs WHERE profile=?", (profile,))
            db.execute("DELETE FROM workflow_states WHERE profile=?", (profile,))
            db.execute("DELETE FROM episodes WHERE profile=?", (profile,))
            return {"corpus_id": replacement}

    def process_one(self, analyze=find_patterns):
        with self.connection() as db:
            job = db.execute(
                "SELECT profile, id FROM jobs WHERE report IS NULL ORDER BY queued, rowid LIMIT 1"
            ).fetchone()
            if job is None:
                return False
            profile, identifier = job
            rows = db.execute("SELECT payload FROM episodes WHERE profile=? ORDER BY id", (profile,)).fetchall()
        episodes = [self._episode_value(raw) for raw, in rows]
        report = json.dumps(analyze(episodes), separators=(",", ":"))
        hypotheses = json.dumps(hypotheses_for(episodes), separators=(",", ":"))
        with self.connection(write=True) as db:
            # A newer upload or a deletion invalidates this result.
            committed = db.execute("UPDATE jobs SET report=? WHERE profile=? AND id=? AND report IS NULL",
                                   (report, profile, identifier))
            if committed.rowcount:
                db.execute("INSERT INTO workflow_states VALUES (?, ?, ?) ON CONFLICT(profile) DO UPDATE SET "
                           "job_id=excluded.job_id, hypotheses=excluded.hypotheses",
                           (profile, identifier, hypotheses))
        return True


def main():
    parser = argparse.ArgumentParser(description="Manage local BorgVR workflow profile credentials")
    parser.add_argument("--database", required=True, type=Path)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("create-profile")
    commands.add_parser("add-device").add_argument("profile")
    revoke = commands.add_parser("revoke-device")
    revoke.add_argument("profile")
    revoke.add_argument("device")
    delete = commands.add_parser("delete-profile")
    delete.add_argument("profile")
    delete.add_argument("--yes", required=True, action="store_true")
    args = parser.parse_args()
    try:
        store = WorkflowStore(args.database)
        if args.command == "create-profile":
            result = store.create_profile()
        elif args.command == "add-device":
            result = store.add_device(args.profile)
        elif args.command == "revoke-device":
            result = {"revoked": store.revoke_device(args.profile, args.device)}
        else:
            result = {"deleted": store.delete_profile(args.profile)}
        print(json.dumps(result))
    except (WorkflowError, OSError, sqlite3.Error, ValueError) as error:
        parser.exit(2, f"Cannot manage workflow profile: {error}\n")


if __name__ == "__main__":
    main()
