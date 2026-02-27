"""Supabase keep-alive pinger for Cloud Run."""

import json
import logging
import os
import time
from datetime import datetime, timezone

import requests
from flask import Flask, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("ping")

TIMEOUT = 10  # seconds per supabase request


def _load_projects() -> list[dict]:
    raw = os.environ.get("SUPABASE_PROJECTS_JSON", "[]")
    projects = json.loads(raw)
    if not projects:
        raise ValueError("SUPABASE_PROJECTS_JSON is empty or missing")
    return projects


def _ping(project: dict) -> dict:
    name = project["name"]
    base = project["url"].rstrip("/")
    key = project["anon_key"]
    table = project.get("table", "healthcheck")

    url = f"{base}/rest/v1/{table}?select=id&limit=1"
    headers = {"apikey": key, "Authorization": f"Bearer {key}"}

    t0 = time.monotonic()
    try:
        r = requests.get(url, headers=headers, timeout=TIMEOUT)
        ms = int((time.monotonic() - t0) * 1000)
        ok = r.status_code < 400
        result = {"name": name, "ok": ok, "status": r.status_code, "ms": ms}
        if not ok:
            result["error"] = r.text[:200]
        return result
    except Exception as exc:
        ms = int((time.monotonic() - t0) * 1000)
        return {
            "name": name,
            "ok": False,
            "status": 0,
            "ms": ms,
            "error": str(exc)[:200],
        }


@app.route("/ping", methods=["POST"])
def ping():
    projects = _load_projects()
    results = []
    for p in projects:
        r = _ping(p)
        log.info(
            "%-25s ok=%-5s status=%d  %4dms",
            r["name"],
            r["ok"],
            r["status"],
            r["ms"],
        )
        results.append(r)

    body = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "results": results,
    }
    failed = any(not r["ok"] for r in results)
    return jsonify(body), 500 if failed else 200


@app.route("/", methods=["GET"])
def health():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
