"""Analyze queued workflow evidence independently of the interactive agent."""

import argparse
import logging
import os
from pathlib import Path
import signal
import sqlite3
import threading

from .workflow_store import WorkflowStore

logger = logging.getLogger(__name__)


def work(store, stop):
    while not stop.is_set():
        try:
            if store.process_one():
                continue
        except sqlite3.Error:
            logger.warning("Workflow database temporarily unavailable")
        stop.wait(0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=os.environ.get("BORGVR_WORKFLOW_DB"))
    args = parser.parse_args()
    if args.database is None:
        parser.error("Set BORGVR_WORKFLOW_DB or pass --database")
    logging.basicConfig(level=logging.INFO)
    stop = threading.Event()
    for name in (signal.SIGINT, signal.SIGTERM):
        signal.signal(name, lambda *_: stop.set())
    work(WorkflowStore(args.database), stop)


if __name__ == "__main__":
    main()
