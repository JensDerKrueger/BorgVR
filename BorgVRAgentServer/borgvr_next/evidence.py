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

from .procedures import CHECKPOINT_BYTES, validate_checkpoint
from .wire import InvalidMessage, decode, encode

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
                CREATE TABLE IF NOT EXISTS checkpoint_state (
                    profile TEXT PRIMARY KEY REFERENCES profiles(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL, imported TEXT
                );
                CREATE TABLE IF NOT EXISTS portable_episodes (
                    episode TEXT PRIMARY KEY REFERENCES episodes(id) ON DELETE CASCADE,
                    portable_id TEXT NOT NULL
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
            if row.rowcount:
                self.bump_checkpoint(db, profile)
            return row.rowcount == 1

    @staticmethod
    def bump_checkpoint(db, profile):
        db.execute("INSERT INTO checkpoint_state(profile, revision) VALUES (?, 2) "
                   "ON CONFLICT(profile) DO UPDATE SET revision=revision+1", (profile,))

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
                self.bump_checkpoint(db, episode["profile"])
                db.execute("INSERT INTO induction(profile, generation, queued) VALUES (?, ?, unixepoch()) "
                           "ON CONFLICT(profile) DO UPDATE SET generation=excluded.generation, queued=excluded.queued, "
                           "lease=NULL, lease_until=NULL, attempts=0", (episode["profile"], uuid4().hex))
            return row.rowcount == 1

    @staticmethod
    def judged_rows(db, profile):
        return db.execute("SELECT coalesce(p.portable_id, e.id) AS id, e.session, e.verdict FROM episodes e "
                          "LEFT JOIN portable_episodes p ON p.episode=e.id WHERE e.profile=? AND e.verdict IS NOT NULL "
                          "ORDER BY e.created DESC, e.rowid DESC LIMIT 24", (profile,)).fetchall()

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
            base = db.execute("SELECT imported FROM checkpoint_state WHERE profile=?", (job["profile"],)).fetchone()
            previous = []
            if base and base["imported"]:
                previous = [{key: value for key, value in row.items() if key in {"claim", "status", "next_steps"}}
                            for row in decode(base["imported"], CHECKPOINT_BYTES)["hypotheses"][:8]]
        return {**dict(job), "lease": lease, "previous": previous, "rows": [
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
            self.bump_checkpoint(db, profile)
            return True

    def read_proposals(self, profile):
        with self.db() as db:
            row = db.execute("SELECT report FROM proposals WHERE profile=?", (profile,)).fetchone()
            awaiting = db.execute("SELECT 1 FROM induction WHERE profile=?", (profile,)).fetchone()
        return {**(decode(row["report"]) if row else {"hypotheses": []}), "induction_pending": awaiting is not None}

    def read_checkpoint(self, profile):
        with self.db() as db:
            state = db.execute("SELECT revision, imported FROM checkpoint_state WHERE profile=?", (profile,)).fetchone()
            episodes = db.execute("SELECT e.*, p.portable_id FROM episodes e LEFT JOIN portable_episodes p ON "
                                  "p.episode=e.id WHERE profile=? ORDER BY e.created, e.rowid", (profile,)).fetchall()
            proposals = db.execute("SELECT report FROM proposals WHERE profile=?", (profile,)).fetchone()
        revision = state["revision"] if state else 1
        base = decode(state["imported"], CHECKPOINT_BYTES) if state and state["imported"] else {}
        entries = {entry["id"]: entry for entry in base.get("entries", [])}
        hypotheses = {row["id"]: row for row in base.get("hypotheses", [])}
        evidence = {row["id"]: row for row in base.get("evidence", [])}
        for episode in episodes:
            key = episode["portable_id"] or episode["id"]
            verdict = decode(episode["verdict"]) if episode["verdict"] else None
            prior = evidence.get(key, {})
            observation = {**prior.get("observation", {}), "session": episode["session"],
                           "events": decode(episode["events"])["events"]}
            if verdict:
                observation["verdict"] = verdict
            evidence[key] = {**prior, "id": key, "episode_id": prior.get("episode_id", key), "kind": "command_trace",
                             "summary": verdict["description"] if verdict else "Not yet assessed.", "observation": observation}
        for proposal in decode(proposals["report"])["hypotheses"] if proposals else ():
            key = "learner." + hashlib.sha256(encode([proposal["situation"], proposal["recommendation"]]).encode()).hexdigest()[:24]
            support, counters = proposal["support"], proposal["counterexamples"]
            refs = [{"id": item, "relation": relation} for values, relation in ((support, "supports"), (counters, "contradicts"))
                    for item in sorted(set(values)) if item in evidence]
            entry = {"id": key, "revision": revision, "source": "learner", "situation": proposal["situation"],
                     "goal": proposal["recommendation"][:240], "evidence_ids": sorted({row["id"] for row in refs}),
                     "guidance": {"revision": 1, "review": "pending", "text": proposal["recommendation"]}}
            if "procedure" in proposal:
                program = proposal["procedure"]
                digest = int(hashlib.sha256(encode(program).encode()).hexdigest()[:7], 16)
                entry["procedure"] = {**program, "revision": digest + 1, "review": "pending"}
            entries[key] = entry
            testing = proposal["status"] == "candidate" or "procedure" in entry
            hypotheses[key] = {"id": key, "revision": revision, "claim": proposal["recommendation"],
                               "status": "testing" if testing else "collecting", "entry": {"id": key, "revision": revision},
                               "next_steps": ["Evaluate on independent episodes." if testing else "Collect independent evidence."],
                               "evidence": refs}
        result = {"kind": "learner_checkpoint", "version": 1, "lineage_id": base.get("lineage_id", profile),
                  "revision": revision, "entries": list(entries.values()), "hypotheses": list(hypotheses.values()),
                  "evidence": list(evidence.values())}
        if len(encode(result)) > CHECKPOINT_BYTES:
            raise InvalidMessage("Checkpoint exceeds bound")
        validate_checkpoint(result)
        return result

    def import_checkpoint(self, profile, data):
        validate_checkpoint(data)
        value = encode(data)
        if len(value) > CHECKPOINT_BYTES:
            raise InvalidMessage("Checkpoint exceeds bound")
        with self.db(write=True) as db:
            state = db.execute("SELECT imported FROM checkpoint_state WHERE profile=?", (profile,)).fetchone()
            if state is not None:
                return "unchanged" if state["imported"] == value else "conflict"
            if db.execute("SELECT 1 FROM episodes WHERE profile=?", (profile,)).fetchone():
                return "conflict"
            db.execute("INSERT INTO checkpoint_state VALUES (?, ?, ?)", (profile, data["revision"], value))
            judged = False
            for row in data["evidence"]:
                if row["kind"] != "command_trace":
                    continue
                observation = row["observation"]
                events, session = observation.get("events"), observation.get("session")
                if (not isinstance(events, list) or len(events) > 128 or not isinstance(session, str)
                        or not 0 < len(session) <= 128 or any(not isinstance(event, dict) or
                                                             not isinstance(event.get("kind"), str) for event in events)
                        or len(encode({"events": events})) > 144 * 1024):
                    continue
                verdict = observation.get("verdict")
                indices = verdict.get("evidence") if isinstance(verdict, dict) else None
                if (isinstance(verdict, dict) and verdict.get("label") in
                        ("aligned", "corrected", "preference", "goal_changed", "inconclusive")
                        and isinstance(verdict.get("description"), str) and 0 < len(verdict["description"]) <= 500
                        and isinstance(indices, list) and len(indices) <= 8 and
                        all(type(i) is int and 0 <= i < len(events) for i in indices)):
                    verdict = {key: verdict[key] for key in ("label", "description", "evidence")}
                else:
                    verdict = None
                identity = uuid4().hex
                db.execute("INSERT INTO episodes(id, profile, session, turn, events, verdict, created) "
                           "VALUES (?, ?, ?, ?, ?, ?, unixepoch())",
                           (identity, profile, session, row["id"], encode({"events": events}), encode(verdict) if verdict else None))
                db.execute("INSERT INTO portable_episodes VALUES (?, ?)", (identity, row["id"]))
                judged |= verdict is not None
            if judged:
                db.execute("INSERT INTO induction(profile, generation, queued) VALUES (?, ?, unixepoch())", (profile, uuid4().hex))
        return "imported"
