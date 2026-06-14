#!/usr/bin/env python3
"""
Pi Media — System Management API
Port 8502 · auth: X-Token header · runs behind nginx /sysapi/
"""
from __future__ import annotations
import http.server, json, os, subprocess, threading, time, uuid
from urllib.parse import urlparse

PASSWORD = os.environ.get("SYSAPI_PASSWORD", "admin")
MEDIA = os.environ.get("MEDIA_DIR", "/home/maan/media")
_UPD  = os.path.join(MEDIA, "update-all.sh")
PORT  = int(os.environ.get("SYSAPI_PORT", "8502"))

# Hardcoded whitelist — user input never reaches shell
CMDS: dict[tuple[str, str], list[str]] = {
    ("restart", "newsmon"):     ["sudo", "systemctl", "restart",  "newsmon"],
    ("restart", "watermarker"): ["sudo", "systemctl", "restart",  "watermarker"],
    ("restart", "writer"): [
        "sudo", "bash", "-c",
        "PHP=$(systemctl list-units --type=service --all 'php*-fpm*' "
        "--no-legend 2>/dev/null | awk '{print $1}' | head -1) && "
        '[ -n "$PHP" ] && systemctl restart "$PHP"; systemctl reload nginx',
    ],
    ("update",  "newsmon"):     [_UPD, "newsmon"],
    ("update",  "watermarker"): [_UPD, "watermarker"],
    ("update",  "writer"):      [_UPD, "writer"],
    ("update",  "all"):         [_UPD, "all"],
}

_tasks: dict[str, dict] = {}
_tlock  = threading.Lock()
_oplock = threading.Lock()


def _run(tid: str, cmd: list[str]) -> None:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        out, ok = (p.stdout + p.stderr).strip(), p.returncode == 0
    except subprocess.TimeoutExpired:
        out, ok = "Timeout (300s)", False
    except Exception as e:
        out, ok = str(e), False
    with _tlock:
        _tasks[tid].update(status="done" if ok else "failed",
                           output=out, ended=time.time())


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass  # silence default request logs

    def _send(self, code: int, data: dict) -> None:
        body = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _auth(self) -> bool:
        return bool(PASSWORD) and self.headers.get("X-Password") == PASSWORD

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "X-Password")
        self.send_header("Access-Control-Allow-Methods", "GET,POST,OPTIONS")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/")

        if path == "/sysapi/health":
            self._send(200, {"ok": True, "busy": _oplock.locked()})
            return

        if path.startswith("/sysapi/task/"):
            if not self._auth():
                self._send(401, {"error": "Unauthorized"}); return
            tid = path.rsplit("/", 1)[-1]
            with _tlock:
                t = dict(_tasks.get(tid, {}))
            self._send(200 if t else 404, t or {"error": "Task not found"})
            return

        self._send(404, {"error": "Not found"})

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/")
        if not self._auth():
            self._send(401, {"error": "Unauthorized"}); return

        parts = path.split("/")   # ["", "sysapi", action, service]
        if len(parts) != 4 or parts[1] != "sysapi":
            self._send(404, {"error": "Not found"}); return

        action, service = parts[2], parts[3]
        cmd = CMDS.get((action, service))
        if not cmd:
            self._send(400, {"error": f"Unknown: {action}/{service}"}); return

        if not _oplock.acquire(blocking=False):
            self._send(409, {"error": "Інша операція вже виконується"}); return

        tid = uuid.uuid4().hex[:8]
        with _tlock:
            _tasks[tid] = {"id": tid, "action": action, "service": service,
                           "status": "running", "output": "", "started": time.time()}

        def run_release():
            try:    _run(tid, cmd)
            finally: _oplock.release()

        threading.Thread(target=run_release, daemon=True).start()
        with _tlock:
            self._send(202, dict(_tasks[tid]))


if __name__ == "__main__":
    if not PASSWORD:
        raise SystemExit("SYSAPI_PASSWORD порожній — перевір /etc/sysapi.env")
    print(f"sysapi слухає на 127.0.0.1:{PORT}", flush=True)
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
