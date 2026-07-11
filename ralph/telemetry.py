#!/usr/bin/env python3
"""ralph/telemetry.py: the observer. Reads run logs (NDJSON) and materializes
telemetry into SQLite; never touches the loop. The log is the whole truth,
append-only, written by the run; this process tails it read-only and is safe
to kill and relaunch anytime: ingestion resumes from a per-log byte offset.

Usage:
  ralph/telemetry.py                 ingest every log under ralph/logs once
  ralph/telemetry.py --follow LOG    tail one log, ingesting in real time
  ralph/telemetry.py --db PATH       override the database location

DB: ralph/telemetry/telemetry.db (machine-local, gitignored; lives with the
root harness, never inside a disposable worktree).
Levels: runs -> passes -> events, plus pass_stats / run_stats / branch_stats
views for aggregation. Event content is truncated to 2000 chars: the full
text lives in the log, the database is for counting and pointing back.
"""
import argparse
import glob
import json
import os
import re
import sqlite3
import sys
import time

DIR = os.path.dirname(os.path.abspath(__file__))
LOGS = os.path.join(DIR, "logs")
TELEMETRY = os.path.join(DIR, "telemetry")
BANNER = re.compile(r"^── pass (\d+) — (\S+) — \d\d:\d\d:\d\d ──")
ENDED = re.compile(r"^── ralph run ended \(exit (\d+)\) ──")
CONTENT_CAP = 2000

SCHEMA = """
CREATE TABLE IF NOT EXISTS ingest (
  log_path TEXT PRIMARY KEY, offset INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY, log_path TEXT UNIQUE, branch TEXT,
  started_at INTEGER, ended_at INTEGER, exit_code INTEGER);
CREATE TABLE IF NOT EXISTS passes (
  id INTEGER PRIMARY KEY, run_id INTEGER NOT NULL REFERENCES runs(id),
  n INTEGER NOT NULL, model TEXT, started_at INTEGER, ended_at INTEGER,
  UNIQUE(run_id, n));
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY, pass_id INTEGER NOT NULL REFERENCES passes(id),
  type TEXT NOT NULL, tool_name TEXT, is_error INTEGER DEFAULT 0,
  started_at INTEGER, finished_at INTEGER, duration_ms INTEGER,
  input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
  total_tokens INTEGER DEFAULT 0, stop_reason TEXT,
  content TEXT, content_len INTEGER DEFAULT 0);
CREATE INDEX IF NOT EXISTS events_pass ON events(pass_id);
CREATE VIEW IF NOT EXISTS pass_stats AS
  SELECT p.run_id, p.n, p.model,
         (p.ended_at - p.started_at) / 1000.0 AS seconds,
         SUM(e.total_tokens) AS tokens,
         SUM(e.input_tokens) AS input_tokens,
         SUM(e.output_tokens) AS output_tokens,
         SUM(e.type = 'tool_call') AS tool_calls,
         SUM(e.is_error) AS errors
  FROM passes p LEFT JOIN events e ON e.pass_id = p.id GROUP BY p.id;
CREATE VIEW IF NOT EXISTS run_stats AS
  SELECT r.id, r.branch, r.exit_code,
         (r.ended_at - r.started_at) / 1000.0 AS seconds,
         COUNT(DISTINCT p.id) AS passes,
         SUM(s.tokens) AS tokens, SUM(s.tool_calls) AS tool_calls,
         SUM(s.errors) AS errors
  FROM runs r LEFT JOIN passes p ON p.run_id = r.id
  LEFT JOIN pass_stats s ON s.run_id = r.id AND s.n = p.n GROUP BY r.id;
CREATE VIEW IF NOT EXISTS branch_stats AS
  SELECT branch, COUNT(*) AS runs, SUM(passes) AS passes,
         SUM(seconds) AS seconds, SUM(tokens) AS tokens,
         SUM(tool_calls) AS tool_calls, SUM(errors) AS errors
  FROM run_stats GROUP BY branch;
"""


def db_connect(path):
    con = sqlite3.connect(path, timeout=30)
    con.execute("PRAGMA journal_mode=WAL")
    con.executescript(SCHEMA)
    return con


class Ingestor:
    """Feeds one log's lines into the DB; tracks the current pass and the
    previous event timestamp so durations can be derived from deltas."""

    def __init__(self, con, log_path):
        self.con = con
        self.log_path = log_path
        branch = os.path.basename(os.path.dirname(log_path))
        cur = con.execute(
            "INSERT INTO runs(log_path, branch) VALUES(?, ?) "
            "ON CONFLICT(log_path) DO UPDATE SET branch = excluded.branch "
            "RETURNING id",
            (log_path, branch),
        )
        self.run_id = cur.fetchone()[0]
        self.pass_id = None
        self.prev_ts = None

    def line(self, raw):
        text = raw.strip()
        if not text:
            return
        m = BANNER.match(text)
        if m:
            cur = self.con.execute(
                "INSERT INTO passes(run_id, n, model) VALUES(?, ?, ?) "
                "ON CONFLICT(run_id, n) DO UPDATE SET model = excluded.model "
                "RETURNING id",
                (self.run_id, int(m.group(1)), m.group(2)),
            )
            self.pass_id = cur.fetchone()[0]
            self.prev_ts = None
            return
        m = ENDED.match(text)
        if m:
            self.con.execute(
                "UPDATE runs SET exit_code = ? WHERE id = ?",
                (int(m.group(1)), self.run_id),
            )
            return
        if not text.startswith("{"):
            return
        try:
            event = json.loads(text)
        except json.JSONDecodeError:
            return
        if event.get("type") != "message_end" or self.pass_id is None:
            return
        self.message(event.get("message", {}))

    def message(self, msg):
        ts = msg.get("timestamp")
        role = msg.get("role")
        usage = msg.get("usage", {})
        started = self.prev_ts
        duration = (ts - started) if (ts and started) else None
        rows = []
        if role == "assistant":
            tokens = (
                usage.get("input", 0),
                usage.get("output", 0),
                usage.get("totalTokens", 0),
            )
            spent = False
            for item in msg.get("content", []):
                kind = item.get("type")
                if kind == "thinking":
                    rows.append(("reasoning", None, 0, item.get("thinking", "")))
                elif kind == "text":
                    rows.append(("assistant_text", None, 0, item.get("text", "")))
                elif kind == "toolCall":
                    rows.append(
                        ("tool_call", item.get("name"), 0,
                         json.dumps(item.get("arguments", {})))
                    )
            if not rows and msg.get("stopReason") == "error":
                rows.append(("assistant_text", None, 1, msg.get("errorMessage", "")))
            for kind, tool, err, content in rows:
                self.insert(
                    kind, tool,
                    err or (1 if msg.get("stopReason") == "error" else 0),
                    started, ts, duration,
                    tokens if not spent else (0, 0, 0),
                    msg.get("stopReason"), content,
                )
                spent = True  # tokens counted once per assistant message
        elif role == "toolResult":
            content = "".join(
                part.get("text", "") for part in msg.get("content", [])
            )
            self.insert(
                "tool_result", msg.get("toolName"),
                1 if msg.get("isError") else 0,
                started, ts, duration, (0, 0, 0), None, content,
            )
        elif role == "user":
            content = "".join(
                part.get("text", "") for part in msg.get("content", [])
            )
            self.insert("user_prompt", None, 0, started, ts, duration,
                        (0, 0, 0), None, content)
        if ts:
            self.prev_ts = ts

    def insert(self, kind, tool, err, started, ts, duration, tokens, stop, content):
        self.con.execute(
            "INSERT INTO events(pass_id, type, tool_name, is_error, started_at,"
            " finished_at, duration_ms, input_tokens, output_tokens,"
            " total_tokens, stop_reason, content, content_len)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (self.pass_id, kind, tool, err, started, ts, duration,
             tokens[0], tokens[1], tokens[2], stop,
             (content or "")[:CONTENT_CAP], len(content or "")),
        )
        if ts:
            self.con.execute(
                "UPDATE passes SET started_at = COALESCE(started_at, ?),"
                " ended_at = ? WHERE id = ?",
                (started or ts, ts, self.pass_id),
            )
            self.con.execute(
                "UPDATE runs SET started_at = COALESCE(started_at, ?),"
                " ended_at = ? WHERE id = ?",
                (started or ts, ts, self.run_id),
            )


def ingest(con, log_path, follow=False):
    """Read complete lines from the saved offset; in follow mode keep
    tailing until the run's end sentinel lands."""
    ing = Ingestor(con, log_path)
    # rebuild pass/timestamp cursor state when resuming mid-log
    row = con.execute(
        "SELECT p.id, MAX(e.finished_at) FROM passes p"
        " LEFT JOIN events e ON e.pass_id = p.id"
        " WHERE p.run_id = ? ORDER BY p.n DESC LIMIT 1",
        (ing.run_id,),
    ).fetchone()
    if row and row[0]:
        ing.pass_id, ing.prev_ts = row[0], row[1]
    offset = con.execute(
        "SELECT offset FROM ingest WHERE log_path = ?", (log_path,)
    ).fetchone()
    offset = offset[0] if offset else 0
    con.execute(
        "INSERT OR IGNORE INTO ingest(log_path, offset) VALUES(?, 0)",
        (log_path,),
    )
    done = False
    with open(log_path, "r", errors="replace") as fh:
        fh.seek(offset)
        while not done:
            line = fh.readline()
            if line.endswith("\n"):
                ing.line(line)
                if ENDED.match(line.strip()):
                    done = True
                offset = fh.tell()
                con.execute(
                    "UPDATE ingest SET offset = ? WHERE log_path = ?",
                    (offset, log_path),
                )
                continue
            # partial or no line: batch mode stops, follow mode waits
            con.commit()
            if not follow:
                break
            fh.seek(offset)
            time.sleep(0.5)
    con.commit()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--follow", metavar="LOG", help="tail one log in real time")
    ap.add_argument("--db", default=os.path.join(TELEMETRY, "telemetry.db"))
    args = ap.parse_args()
    os.makedirs(LOGS, exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.db)), exist_ok=True)
    con = db_connect(args.db)
    if args.follow:
        ingest(con, os.path.abspath(args.follow), follow=True)
    else:
        for log in sorted(glob.glob(os.path.join(LOGS, "*", "*.ndjson"))):
            ingest(con, log)
            print(f"telemetry: ingested {log}", file=sys.stderr)
    con.close()


if __name__ == "__main__":
    main()
