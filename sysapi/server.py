#!/usr/bin/env python3
"""
Pi Media — System Management API
Port 8502 · auth: X-Password header · runs behind nginx /sysapi/
"""
from __future__ import annotations
import http.server, json, os, subprocess, threading, time, uuid
from urllib.parse import urlparse

PASSWORD  = os.environ.get("SYSAPI_PASSWORD", "admin")
MEDIA     = os.environ.get("MEDIA_DIR", "/home/maan/media")
HUB_DIR   = os.environ.get("HUB_DIR",   "/var/www/hub")
_UPD      = os.path.join(MEDIA, "update-all.sh")
_UPD_SELF = os.path.join(MEDIA, "sysapi", "update-media.sh")
PORT      = int(os.environ.get("SYSAPI_PORT", "8502"))

# Hardcoded whitelist — user input never reaches shell
# None = special in-process handling (see do_POST)
CMDS: dict[tuple[str, str], list[str] | None] = {
    ("restart", "newsmon"):     ["sudo", "systemctl", "restart",  "newsmon"],
    ("restart", "watermarker"): ["sudo", "systemctl", "restart",  "watermarker"],
    ("restart", "writer"): [
        "sudo", "bash", "-c",
        "PHP=$(systemctl list-units --type=service --all 'php*-fpm*' "
        "--no-legend 2>/dev/null | awk '{print $1}' | head -1) && "
        '[ -n "$PHP" ] && systemctl restart "$PHP" && systemctl reload nginx',
    ],
    ("restart", "sysapi"):      None,          # self-restart: special handling
    ("update",  "newsmon"):     [_UPD, "newsmon"],
    ("update",  "watermarker"): [_UPD, "watermarker"],
    ("update",  "writer"):      [_UPD, "writer"],
    ("update",  "all"):         [_UPD, "all"],
    ("update",  "media"):       [_UPD_SELF],   # git pull media + оновити хаб
}

_tasks: dict[str, dict] = {}
_tlock  = threading.Lock()
_oplock = threading.Lock()


def _get_stats() -> dict:
    r: dict = {}
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            r["temp_c"] = round(int(f.read().strip()) / 1000, 1)
    except Exception:
        r["temp_c"] = None
    try:
        with open("/proc/loadavg") as f:
            p = f.read().split()
            r["load"] = [float(p[0]), float(p[1]), float(p[2])]
    except Exception:
        r["load"] = None
    try:
        mem: dict[str, int] = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mem[k.strip()] = int(v.strip().split()[0])
        total, avail = mem["MemTotal"], mem["MemAvailable"]
        r["ram_total_mb"] = total // 1024
        r["ram_used_mb"]  = (total - avail) // 1024
        r["ram_pct"]      = round((total - avail) / total * 100)
    except Exception:
        r["ram_total_mb"] = r["ram_used_mb"] = r["ram_pct"] = None
    try:
        st = os.statvfs("/")
        total_b = st.f_blocks * st.f_frsize
        used_b  = (st.f_blocks - st.f_bavail) * st.f_frsize
        r["disk_total_gb"] = round(total_b / 1e9, 1)
        r["disk_used_gb"]  = round(used_b  / 1e9, 1)
        r["disk_pct"]      = round(used_b / total_b * 100)
    except Exception:
        r["disk_total_gb"] = r["disk_used_gb"] = r["disk_pct"] = None
    try:
        with open("/proc/uptime") as f:
            r["uptime_s"] = int(float(f.read().split()[0]))
    except Exception:
        r["uptime_s"] = None
    return r


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

        if path == "/sysapi/stats":
            self._send(200, _get_stats())
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
        if (action, service) not in CMDS:
            self._send(400, {"error": f"Unknown: {action}/{service}"}); return
        cmd = CMDS[(action, service)]

        if not _oplock.acquire(blocking=False):
            self._send(409, {"error": "Інша операція вже виконується"}); return

        thread_started = False
        try:
            tid = uuid.uuid4().hex[:8]
            with _tlock:
                # Evict completed tasks older than 1 hour to prevent unbounded growth
                cutoff = time.time() - 3600
                stale = [k for k, v in _tasks.items()
                         if v["status"] != "running" and v.get("ended", 0) < cutoff]
                for k in stale:
                    del _tasks[k]
                _tasks[tid] = {"id": tid, "action": action, "service": service,
                               "status": "running", "output": "", "started": time.time()}

            if action == "restart" and service == "sysapi":
                # Позначаємо "done" ДО перезапуску — після нього задача зникне з пам'яті
                def _self_restart():
                    time.sleep(0.2)
                    with _tlock:
                        _tasks[tid].update(status="done", output="Перезапуск sysapi…",
                                           ended=time.time())
                    _oplock.release()
                    time.sleep(0.3)
                    subprocess.run(["sudo", "systemctl", "restart", "sysapi"])
                threading.Thread(target=_self_restart, daemon=True).start()
            else:
                def run_release():
                    try:    _run(tid, cmd)
                    finally: _oplock.release()
                threading.Thread(target=run_release, daemon=True).start()
            thread_started = True
        except Exception:
            if not thread_started:
                _oplock.release()
            raise

        with _tlock:
            response_data = dict(_tasks[tid])
        self._send(202, response_data)


if __name__ == "__main__":
    if not PASSWORD:
        raise SystemExit("SYSAPI_PASSWORD порожній — перевір /etc/sysapi.env")
    print(f"sysapi слухає на 127.0.0.1:{PORT}", flush=True)
    http.server.HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
