"""Opt-in per-profile evidence queue shared by independent processes."""

from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import re
import secrets
import sqlite3
import stat
from uuid import uuid4

from .wire import decode, encode

TOKEN = re.compile(r"bn1_[0-9a-f]{64}")


class Evidence:
    def __init__(self, path):
        self.path = Path(path)
        directory = self.path.parent.stat()
        if directory.st_uid != os.getuid() or directory.st_mode & 0o077 or self.path.is_symlink():
            raise ValueError("Evidence storage requires a private directory")
        try:
            fd = os.open(self.path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            pass
        else:
            os.close(fd)
        info = self.path.lstat()
        if info.st_uid != os.getuid() or info.st_nlink != 1 or not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077:
            raise ValueError("Evidence storage requires a private regular file")
        with self.db() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS profiles (
                    id TEXT PRIMARY KEY, token BLOB UNIQUE NOT NULL
                );
                CREATE TABLE IF NOT EXISTS episodes (
                    id TEXT PRIMARY KEY, profile TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    session TEXT NOT NULL, turn TEXT NOT NULL, events TEXT NOT NULL, verdict TEXT,
                    created INTEGER NOT NULL, lease TEXT, lease_until INTEGER, attempts INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(profile, session, turn)
                );
                CREATE INDEX IF NOT EXISTS episodes_queue ON episodes(verdict, lease_until, created);
                CREATE INDEX IF NOT EXISTS episodes_profile ON episodes(profile, created);
                CREATE TABLE IF NOT EXISTS proposals (
                    profile TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
                    episode_ids TEXT NOT NULL, report TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS induction (
                    profile TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
                    generation TEXT NOT NULL, queued INTEGER NOT NULL,
                    lease TEXT, lease_until INTEGER, attempts INTEGER NOT NULL DEFAULT 0
                );
            """)

    @contextmanager
    def db(self, *, write=False):
        conn = sqlite3.connect(self.path, timeout=2)
        conn.row_factory = sqlite3.Row
        try:
            conn.execute("PRAGMA foreign_keys=ON")
            conn.execute("PRAGMA secure_delete=ON")
            conn.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield conn
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()

    def provision(self):
        token = "bn1_" + secrets.token_hex(32)
        profile = uuid4().hex
        with self.db(write=True) as db:
            if db.execute("SELECT count(*) FROM profiles").fetchone()[0] >= 64:
                raise ValueError("Profile limit reached")
            db.execute("INSERT INTO profiles VALUES (?, ?)", (profile, hashlib.sha256(token.encode()).digest()))
        return profile, token

    def profile(self, token):
        if not TOKEN.fullmatch(token or ""):
            return None
        digest = hashlib.sha256(token.encode()).digest()
        with self.db() as db:
            row = db.execute("SELECT id FROM profiles WHERE token = ?", (digest,)).fetchone()
        return row["id"] if row else None

    def submit(self, profile, session, turn, events):
        value = encode({"events": events})
        if len(value) > 144 * 1024:
            return False
        with self.db(write=True) as db:
            if db.execute("SELECT count(*) FROM episodes WHERE profile=?", (profile,)).fetchone()[0] >= 128:
                return False
            row = db.execute("INSERT INTO episodes(id, profile, session, turn, events, created) "
                             "VALUES (?, ?, ?, ?, ?, unixepoch()) ON CONFLICT(profile, session, turn) DO NOTHING",
                             (uuid4().hex, profile, session, turn, value))
            return row.rowcount == 1

    def claim(self):
        with self.db(write=True) as db:
            row = db.execute("SELECT * FROM episodes WHERE verdict IS NULL AND attempts < 3 AND "
                             "(lease_until IS NULL OR lease_until <= unixepoch()) ORDER BY created, rowid LIMIT 1").fetchone()
            if row is None:
                return None
            lease = uuid4().hex
            db.execute("UPDATE episodes SET lease=?, lease_until=unixepoch()+300, attempts=attempts+1 WHERE id=?",
                       (lease, row["id"]))
        return {**dict(row), "lease": lease, "events": decode(row["events"])["events"]}

    def settle(self, episode, verdict):
        with self.db(write=True) as db:
            row = db.execute("UPDATE episodes SET verdict=?, lease=NULL, lease_until=NULL "
                             "WHERE id=? AND profile=? AND lease=?",
                             (encode(verdict), episode["id"], episode["profile"], episode["lease"]))
            if row.rowcount:
                db.execute("INSERT INTO induction(profile, generation, queued) VALUES (?, ?, unixepoch()) "
                           "ON CONFLICT(profile) DO UPDATE SET generation=excluded.generation, queued=excluded.queued, "
                           "lease=NULL, lease_until=NULL, attempts=0", (episode["profile"], uuid4().hex))
            return row.rowcount == 1

    @staticmethod
    def judged_rows(db, profile):
        return db.execute("SELECT id, session, verdict FROM episodes WHERE profile=? AND verdict IS NOT NULL "
                          "ORDER BY created DESC, rowid DESC LIMIT 24", (profile,)).fetchall()

    def claim_induction(self):
        with self.db(write=True) as db:
            job = db.execute("SELECT profile, generation FROM induction WHERE attempts<3 AND "
                             "(lease_until IS NULL OR lease_until<=unixepoch()) ORDER BY queued, rowid LIMIT 1").fetchone()
            if job is None:
                return None
            lease = uuid4().hex
            db.execute("UPDATE induction SET lease=?, lease_until=unixepoch()+300, attempts=attempts+1 WHERE profile=?",
                       (lease, job["profile"]))
            rows = self.judged_rows(db, job["profile"])
        return {**dict(job), "lease": lease, "rows": [
            {**dict(row), "verdict": decode(row["verdict"])} for row in rows]}

    def finish_induction(self, job, report):
        profile = job["profile"]
        with self.db(write=True) as db:
            accepted = db.execute("DELETE FROM induction WHERE profile=? AND generation=? AND lease=?",
                                  (profile, job["generation"], job["lease"]))
            if not accepted.rowcount:
                return False
            episode_ids = [row["id"] for row in job["rows"]]
            db.execute("INSERT INTO proposals VALUES (?, ?, ?) ON CONFLICT(profile) DO UPDATE SET "
                       "episode_ids=excluded.episode_ids, report=excluded.report",
                       (profile, encode(episode_ids), encode({"hypotheses": report})))
            return True

    def read_proposals(self, profile):
        with self.db() as db:
            row = db.execute("SELECT report FROM proposals WHERE profile=?", (profile,)).fetchone()
            awaiting = db.execute("SELECT 1 FROM induction WHERE profile=?", (profile,)).fetchone()
        return {**(decode(row["report"]) if row else {"hypotheses": []}), "induction_pending": awaiting is not None}
