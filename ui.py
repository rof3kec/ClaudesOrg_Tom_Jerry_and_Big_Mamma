#!/usr/bin/env python3
"""
The House -- Web Dashboard for Tom, Jerry & Big Mamma

Usage:
    pip install flask
    python ui.py

    Then open http://localhost:5005
"""

import os
import sys
import json
import hashlib
import shutil
import subprocess
import threading
import time
from pathlib import Path

try:
    from flask import Flask, jsonify, request, send_file
except ImportError:
    print("\n  Flask is required. Install with:\n")
    print("    pip install flask\n")
    sys.exit(1)

# ── Config ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR = Path(__file__).parent.resolve()
CONFIG_FILE = SCRIPT_DIR / "ui-locations.json"
PORT = int(os.environ.get("HOUSE_PORT", 5005))

LOG_MAP = {
    "all": ["claude-supervisor.log", "claude-worker.log", "claude-qa.log"],
    "big_mamma": ["claude-supervisor.log"],
    "tom": ["claude-worker.log"],
    "spike": ["claude-qa.log"],
}

INSTANCES_FILE = SCRIPT_DIR / ".house-instances"

SPECIALIZATIONS = [
    {"id": "fullstack",  "label": "Fullstack",      "desc": "General-purpose worker"},
    {"id": "architect",  "label": "Architect",       "desc": "System design & architecture"},
    {"id": "backend",    "label": "Backend",         "desc": "APIs, services & server logic"},
    {"id": "frontend",   "label": "Frontend",        "desc": "UI, components & styling"},
    {"id": "data",       "label": "Data",            "desc": "Data models, DB & migrations"},
    {"id": "platform",   "label": "Platform",        "desc": "CI/CD, infra & deployment"},
    {"id": "qa",         "label": "QA",              "desc": "Testing & quality assurance"},
    {"id": "design",     "label": "Design System",   "desc": "Design tokens & UI patterns"},
]

app = Flask(__name__)

# ── Shutdown-on-close timer ────────────────────────────────────────────────────

_shutdown_timer = None
_shutdown_lock = threading.Lock()


# ── Find bash (Windows-aware) ─────────────────────────────────────────────────

def _find_bash():
    """Find bash executable. On Windows, prefers Git Bash over WSL bash."""
    if sys.platform == "win32":
        # Try Git for Windows first (WSL's System32\bash.exe doesn't work here)
        git = shutil.which("git")
        if git:
            git_dir = Path(git).resolve().parent.parent
            for sub in ("bin/bash.exe", "usr/bin/bash.exe"):
                candidate = git_dir / sub
                if candidate.exists():
                    return str(candidate)
        for p in (
            r"C:\Program Files\Git\bin\bash.exe",
            r"C:\Program Files (x86)\Git\bin\bash.exe",
        ):
            if os.path.exists(p):
                return p
        # Fall back to PATH, but skip WSL bash (System32\bash.exe)
        bash = shutil.which("bash")
        if bash and "system32" not in bash.lower():
            return bash
    else:
        bash = shutil.which("bash")
        if bash:
            return bash
    return None


BASH = _find_bash()


# ── Stop via claude-stop.sh (single source of truth for process management) ──

def _run_stop_script(path, force=False, timeout=15):
    """Delegate all stop/cleanup to claude-stop.sh.

    This is the canonical way to stop a house instance. The stop script handles:
    - Process tree killing (Windows-aware taskkill /T /F)
    - State/PID file cleanup
    - Task reset ([!] -> [ ])
    - Worktree cleanup
    Returns True if the script ran successfully.
    """
    if not BASH:
        return False
    cmd = [BASH, str(SCRIPT_DIR / "claude-stop.sh"), "--location", path]
    if force:
        cmd.insert(2, "--force")
    try:
        r = subprocess.run(cmd, cwd=str(SCRIPT_DIR),
                           capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0
    except Exception:
        return False


def _nuke_claude_processes():
    """Nuclear fallback: find and kill ALL node.exe processes running claude.

    Uses wmic to query process command lines. This catches any orphaned
    claude processes that survived the stop script cleanup.
    Returns the number of processes killed.
    """
    if sys.platform != "win32":
        return 0

    killed = 0
    try:
        r = subprocess.run(
            ["wmic", "process", "where", "Name='node.exe'",
             "get", "CommandLine,ProcessId", "/FORMAT:CSV"],
            capture_output=True, text=True, timeout=15,
        )
        for line in r.stdout.splitlines():
            if "claude" in line.lower():
                parts = line.strip().rstrip(",").split(",")
                pid_str = parts[-1].strip() if parts else ""
                if pid_str.isdigit():
                    try:
                        subprocess.run(
                            ["taskkill", "/T", "/F", "/PID", pid_str],
                            capture_output=True, timeout=5,
                        )
                        killed += 1
                    except Exception:
                        pass
    except Exception:
        pass
    return killed


def _deregister_instance(path):
    """Remove a location from the .house-instances registry."""
    norm = path.replace("\\", "/")
    if INSTANCES_FILE.exists():
        try:
            lines = INSTANCES_FILE.read_text(encoding="utf-8").splitlines()
            lines = [l for l in lines if l.strip() != norm]
            INSTANCES_FILE.write_text("\n".join(lines) + ("\n" if lines else ""),
                                      encoding="utf-8")
        except OSError:
            pass


# ── Utilities ───────────────────────────────────────────────────────────────────


def load_locations():
    try:
        return json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []


def save_locations(locs):
    CONFIG_FILE.write_text(json.dumps(locs, indent=2), encoding="utf-8")


def read_kv(path):
    """Read a KEY=VALUE status file into a dict."""
    data = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if "=" in line:
                    k, _, v = line.strip().partition("=")
                    data[k] = v
    except OSError:
        pass
    return data


def parse_tasks(filepath):
    tasks = []
    prefixes = [("[ ] ", "pending"), ("[q] ", "qa"),
                ("[x] ", "done"), ("[!] ", "in_progress"), ("[-] ", "failed")]
    try:
        with open(filepath, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f, 1):
                raw = line.rstrip("\n\r")
                for prefix, status in prefixes:
                    if raw.startswith(prefix):
                        tasks.append({"line": i, "status": status, "desc": raw[4:]})
                        break
    except OSError:
        pass
    return tasks


def _is_status_fresh(kv):
    """Check if a status file's timestamp is recent (< 2 min)."""
    ts = kv.get("UPDATED") or kv.get("LAST_CHECK") or "0"
    try:
        return (time.time() - int(ts)) < 120
    except (ValueError, TypeError):
        return False


def _live_state(kv):
    """Return agent state from status KV, or 'offline' if stale."""
    state = kv.get("STATE", "offline")
    if state == "offline":
        return "offline"
    return state if _is_status_fresh(kv) else "offline"


def get_agents(loc):
    agents = []

    # Big Mamma — infer from lock file
    running = os.path.exists(os.path.join(loc, ".claude-start.lock"))
    agents.append({
        "id": "big_mamma", "name": "Big Mamma",
        "role": "Supervisor", "state": "running" if running else "offline", "task": "",
    })

    # Tom
    ws = read_kv(os.path.join(loc, ".worker-status"))
    tom_state = _live_state(ws)
    agents.append({
        "id": "tom", "name": "Tom",
        "role": "Primary Worker",
        "state": tom_state,
        "task": ws.get("TASK_DESC", "") if tom_state != "offline" else "",
    })

    # Jerry xN (read count from .house-jerries, default 2)
    jerry_count = 2
    jerries_file = os.path.join(loc, ".house-jerries")
    try:
        jerry_count = int(Path(jerries_file).read_text().strip())
    except (OSError, ValueError):
        pass

    # Read Jerry specializations
    jerry_specs = {}
    specs_file = os.path.join(loc, ".house-jerry-specs.json")
    try:
        jerry_specs = json.loads(Path(specs_file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass

    for i in range(jerry_count):
        ps = read_kv(os.path.join(loc, f".parallel-status-{i}"))
        jerry_state = _live_state(ps)
        spec = jerry_specs.get(str(i), "fullstack")
        spec_label = next((s["label"] for s in SPECIALIZATIONS if s["id"] == spec), "Fullstack")
        agents.append({
            "id": f"jerry_{i}", "name": f"Jerry #{i}",
            "role": f"Parallel Worker · {spec_label}",
            "state": jerry_state,
            "task": ps.get("TASK_DESC", "") if jerry_state != "offline" else "",
            "spec": spec,
        })

    # Spike
    qs = read_kv(os.path.join(loc, ".qa-status"))
    agents.append({
        "id": "spike", "name": "Spike",
        "role": "QA Enforcer",
        "state": _live_state(qs),
        "task": "",
    })

    return agents


def files_etag(loc, filenames):
    """Fast hash of file sizes + mtimes to detect changes."""
    parts = []
    for f in filenames:
        try:
            st = os.stat(os.path.join(loc, f))
            parts.append(f"{f}:{st.st_size}:{st.st_mtime_ns}")
        except OSError:
            pass
    return hashlib.md5("|".join(parts).encode()).hexdigest()[:12]


def read_merged_logs(loc, filenames, limit=500):
    entries = []
    for fname in filenames:
        fpath = os.path.join(loc, fname)
        try:
            with open(fpath, encoding="utf-8", errors="replace") as f:
                for line in f:
                    stripped = line.rstrip("\n\r")
                    if stripped:
                        entries.append(stripped)
        except OSError:
            pass

    # Sort by timestamp when merging multiple files
    if len(filenames) > 1:
        def ts_key(line):
            if line.startswith("[") and "]" in line[1:]:
                return line[1:line.index("]", 1)]
            return ""
        entries.sort(key=ts_key)

    return entries[-limit:]


# ── API Routes ──────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return send_file(str(SCRIPT_DIR / "ui.html"))


@app.route("/api/locations", methods=["GET"])
def api_list_locations():
    return jsonify(load_locations())


@app.route("/api/locations", methods=["POST"])
def api_add_location():
    data = request.json or {}
    path = data.get("path", "").replace("\\", "/")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Directory not found"}), 400
    name = data.get("name", "").strip() or os.path.basename(path.rstrip("/"))
    locs = load_locations()
    if any(l["path"] == path for l in locs):
        return jsonify({"error": "Already added"}), 400
    locs.append({"name": name, "path": path})
    save_locations(locs)
    return jsonify({"ok": True})


@app.route("/api/locations/<int:idx>", methods=["DELETE"])
def api_remove_location(idx):
    locs = load_locations()
    if 0 <= idx < len(locs):
        locs.pop(idx)
        save_locations(locs)
    return jsonify({"ok": True})


@app.route("/api/overview")
def api_overview():
    locs = load_locations()
    result = []
    for loc in locs:
        p = loc["path"]
        running = os.path.exists(os.path.join(p, ".claude-start.lock"))
        tasks = parse_tasks(os.path.join(p, "TASKS.md"))
        result.append({
            "name": loc["name"], "path": p, "running": running,
            "pending": sum(1 for t in tasks if t["status"] == "pending"),
            "in_progress": sum(1 for t in tasks if t["status"] == "in_progress"),
            "qa": sum(1 for t in tasks if t["status"] == "qa"),
            "done": sum(1 for t in tasks if t["status"] == "done"),
            "failed": sum(1 for t in tasks if t["status"] == "failed"),
        })
    return jsonify(result)


@app.route("/api/state")
def api_state():
    path = request.args.get("path", "")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    return jsonify({
        "agents": get_agents(path),
        "tasks": parse_tasks(os.path.join(path, "TASKS.md")),
        "running": os.path.exists(os.path.join(path, ".claude-start.lock")),
    })


@app.route("/api/logs")
def api_logs():
    path = request.args.get("path", "")
    filt = request.args.get("filter", "all")
    client_etag = request.args.get("etag", "")
    limit = min(int(request.args.get("limit", "500")), 2000)

    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400

    filenames = LOG_MAP.get(filt, LOG_MAP["all"])
    etag = files_etag(path, filenames)

    if client_etag and client_etag == etag:
        return jsonify({"changed": False, "etag": etag})

    entries = read_merged_logs(path, filenames, limit)
    return jsonify({"changed": True, "etag": etag, "entries": entries})


@app.route("/api/logs/clear", methods=["POST"])
def api_clear_logs():
    data = request.json or {}
    path = data.get("path", "")
    filt = data.get("filter", "all")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    filenames = LOG_MAP.get(filt, LOG_MAP["all"])
    for fname in filenames:
        fpath = os.path.join(path, fname)
        try:
            open(fpath, "w", encoding="utf-8").close()
        except OSError:
            pass
    return jsonify({"ok": True})


@app.route("/api/discover")
def api_discover():
    """Read the instances registry and auto-add any running locations."""
    discovered = []
    if not INSTANCES_FILE.exists():
        return jsonify({"discovered": discovered})

    locs = load_locations()
    existing_paths = {l["path"] for l in locs}
    try:
        lines = INSTANCES_FILE.read_text(encoding="utf-8").strip().splitlines()
    except OSError:
        return jsonify({"discovered": discovered})

    for line in lines:
        path = line.strip()
        if not path or not os.path.isdir(path):
            continue
        norm = path.replace("\\", "/")
        lock = os.path.join(norm, ".claude-start.lock")
        if not os.path.exists(lock):
            continue
        if norm not in existing_paths:
            name = os.path.basename(norm.rstrip("/"))
            locs.append({"name": name, "path": norm})
            existing_paths.add(norm)
            discovered.append({"name": name, "path": norm})

    if discovered:
        save_locations(locs)

    return jsonify({"discovered": discovered})


@app.route("/api/branch")
def api_branch():
    path = request.args.get("path", "")
    try:
        r = subprocess.run(
            ["git", "branch", "--show-current"],
            cwd=path, capture_output=True, text=True, timeout=5,
        )
        branch = r.stdout.strip()
        return jsonify({"branch": branch, "protected": branch in ("main", "master")})
    except Exception:
        return jsonify({"branch": "", "protected": False})


@app.route("/api/specializations")
def api_specializations():
    return jsonify(SPECIALIZATIONS)


@app.route("/api/jerry-specs")
def api_get_jerry_specs():
    path = request.args.get("path", "")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    specs_file = os.path.join(path, ".house-jerry-specs.json")
    try:
        specs = json.loads(Path(specs_file).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        specs = {}
    return jsonify(specs)


@app.route("/api/jerry-specs", methods=["PUT"])
def api_set_jerry_specs():
    data = request.json or {}
    path = data.get("path", "")
    specs = data.get("specs", {})
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    specs_file = os.path.join(path, ".house-jerry-specs.json")
    try:
        Path(specs_file).write_text(json.dumps(specs, indent=2), encoding="utf-8")
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/start", methods=["POST"])
def api_start():
    data = request.json or {}
    path = data.get("path", "")
    branch = data.get("branch", "")

    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400

    # ── Pre-validate (catch errors before launching async subprocess) ──

    if not BASH:
        return jsonify({"error": "bash not found. Install Git for Windows and ensure it's in PATH."}), 500

    if not os.path.isdir(os.path.join(path, ".git")):
        return jsonify({"error": f"Not a git repository: {path}"}), 400

    if branch and branch in ("main", "master"):
        return jsonify({"error": f"Cannot start on '{branch}'. Use a dev branch."}), 400

    # Check origin remote
    try:
        r = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            cwd=path, capture_output=True, text=True, timeout=5,
        )
        if r.returncode != 0:
            return jsonify({"error": "No 'origin' remote configured. Add one with: git remote add origin <url>"}), 400
    except Exception:
        pass

    # Check for active lock (already running)
    lock_file = os.path.join(path, ".claude-start.lock")
    if os.path.exists(lock_file):
        try:
            old_pid = int(Path(lock_file).read_text(encoding="utf-8").strip())
            try:
                os.kill(old_pid, 0)
                return jsonify({"error": f"Already running (PID {old_pid}). Stop it first."}), 400
            except OSError:
                pass  # PID not running — stale lock, script will clean it up
        except (ValueError, OSError):
            pass

    # Check start script exists
    start_script = str(SCRIPT_DIR / "claude-start.sh")
    if not os.path.isfile(start_script):
        return jsonify({"error": f"claude-start.sh not found in {SCRIPT_DIR}"}), 500

    # ── Launch ──

    jerries = data.get("jerries", "")

    cmd = [BASH, start_script, "--auto", "--location", path]
    if branch:
        cmd.extend(["--branch", branch])
    if jerries != "":
        cmd.extend(["--jerries", str(jerries)])

    try:
        # Redirect stderr to a log file for debugging (instead of DEVNULL)
        start_log = os.path.join(path, "claude-start-stderr.log")
        with open(start_log, "w", encoding="utf-8") as err_f:
            subprocess.Popen(
                cmd, cwd=str(SCRIPT_DIR),
                stdout=subprocess.DEVNULL, stderr=err_f,
            )
    except FileNotFoundError:
        return jsonify({"error": "bash not found. Install Git for Windows."}), 500
    except Exception as e:
        return jsonify({"error": f"Failed to start: {e}"}), 500

    return jsonify({"ok": True})


@app.route("/api/stop", methods=["POST"])
def api_stop():
    """Stop a location — delegates to claude-stop.sh for all process/state cleanup."""
    data = request.json or {}
    path = data.get("path", "")
    force = data.get("force", False)

    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400

    ok = _run_stop_script(path, force=force)
    return jsonify({"ok": ok})


@app.route("/api/kill-switch", methods=["POST"])
def api_kill_switch():
    """Nuclear option: force-stop via script + sweep for orphaned processes.

    Goes beyond /api/stop by using --force and sweeping for orphans.
    The stop script handles: process killing, state cleanup, task reset, worktree cleanup.
    """
    data = request.json or {}
    path = data.get("path", "")

    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400

    # Step 1: Force-stop via script (handles process trees, state, tasks, worktrees)
    _run_stop_script(path, force=True)

    # Step 2: Nuclear sweep for any surviving orphaned claude processes
    time.sleep(0.5)
    orphans = _nuke_claude_processes()

    # Step 3: Deregister from instances
    _deregister_instance(path)

    return jsonify({"ok": True, "orphans": orphans})


@app.route("/api/stop-all", methods=["POST"])
def api_stop_all():
    """Schedule force-stop of all running locations (5s delay).
    Called via sendBeacon when the browser window closes.
    If the dashboard reconnects (e.g. page refresh), /api/cancel-stop-all cancels it."""
    global _shutdown_timer
    with _shutdown_lock:
        if _shutdown_timer:
            _shutdown_timer.cancel()
        _shutdown_timer = threading.Timer(5.0, _execute_stop_all)
        _shutdown_timer.daemon = True
        _shutdown_timer.start()
    return jsonify({"ok": True})


@app.route("/api/cancel-stop-all", methods=["POST"])
def api_cancel_stop_all():
    """Cancel a pending stop-all (called on page load to handle refresh)."""
    global _shutdown_timer
    with _shutdown_lock:
        if _shutdown_timer:
            _shutdown_timer.cancel()
            _shutdown_timer = None
    return jsonify({"ok": True})


def _execute_stop_all():
    """Force-stop all running locations via claude-stop.sh."""
    global _shutdown_timer
    locs = load_locations()
    for loc in locs:
        p = loc["path"]
        lock = os.path.join(p, ".claude-start.lock")
        if os.path.exists(lock):
            _run_stop_script(p, force=True, timeout=10)

    # Nuclear sweep for any remaining orphans
    _nuke_claude_processes()

    with _shutdown_lock:
        _shutdown_timer = None


@app.route("/api/task", methods=["POST"])
def api_add_task():
    data = request.json or {}
    path = data.get("path", "")
    task = data.get("task", "").strip()
    if not task:
        return jsonify({"error": "Empty task"}), 400
    filepath = os.path.join(path, "TASKS.md")
    try:
        with open(filepath, "a", encoding="utf-8") as f:
            f.write(f"\n[ ] {task}\n")
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/task/retry", methods=["POST"])
def api_retry_task():
    data = request.json or {}
    path = data.get("path", "")
    line_num = data.get("line", 0)
    filepath = os.path.join(path, "TASKS.md")
    try:
        with open(filepath, encoding="utf-8") as f:
            lines = f.readlines()
        if 0 < line_num <= len(lines) and lines[line_num - 1].startswith("[-] "):
            lines[line_num - 1] = "[ ] " + lines[line_num - 1][4:]
            with open(filepath, "w", encoding="utf-8") as f:
                f.writelines(lines)
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/tasks/raw")
def api_tasks_raw():
    path = request.args.get("path", "")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    filepath = os.path.join(path, "TASKS.md")
    try:
        content = Path(filepath).read_text(encoding="utf-8")
    except FileNotFoundError:
        content = ""
    except OSError as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"content": content})


@app.route("/api/tasks/raw", methods=["PUT"])
def api_tasks_save():
    data = request.json or {}
    path = data.get("path", "")
    content = data.get("content", "")
    if not path or not os.path.isdir(path):
        return jsonify({"error": "Invalid path"}), 400
    filepath = os.path.join(path, "TASKS.md")
    try:
        Path(filepath).write_text(content, encoding="utf-8")
        return jsonify({"ok": True})
    except OSError as e:
        return jsonify({"error": str(e)}), 500


# ── Main ────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import io, sys as _sys
    # Force UTF-8 stdout on Windows to handle emoji in log output
    if _sys.stdout.encoding != "utf-8":
        _sys.stdout = io.TextIOWrapper(_sys.stdout.buffer, encoding="utf-8", errors="replace")
    print()
    print("  The House -- Dashboard")
    print(f"  http://localhost:{PORT}")
    print()
    print("  Ctrl+C to stop the dashboard")
    print()
    app.run(host="0.0.0.0", port=PORT, debug=False)
