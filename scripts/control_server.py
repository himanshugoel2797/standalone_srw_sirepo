#!/usr/bin/env python3
"""Sirepo_Win in-guest control endpoint.

Runs as root inside the QEMU guest, listening on 0.0.0.0:<port> (default 8312)
so the host-side setup.ps1 UI can hit it via slirp's hostfwd. Provides
operations that need to happen inside the VM:

  GET  /status          git revs + sirepo.service active state
  POST /update          git pull pykern+sirepo, pip install -e, restart sirepo
  POST /sbatch_creds    write /var/lib/sirepo/sbatch.env + restart sirepo
  POST /restart         systemctl restart sirepo.service

Stdlib-only (http.server, json, subprocess) -- the QEMU bundle install path
already drags in python3 via cloud-init's apt-get, no extra deps. Inlined
into cloud-init's write_files by bootstrap-qemu.ps1.

Auth: loopback-only via slirp NAT. The hostfwd is 127.0.0.1:<port> on the
Windows side, so only local processes (i.e. the setup.ps1 UI) can reach us.
"""
import http.server
import json
import os
import subprocess
import sys
from urllib.parse import urlparse


VENV_PIP   = "/opt/sirepo-venv/bin/pip"
SBATCH_ENV = "/var/lib/sirepo/sbatch.env"
SIREPO_SVC = "sirepo.service"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def git_rev(path):
    r = run(["git", "-C", path, "rev-parse", "--short", "HEAD"])
    return r.stdout.strip() if r.returncode == 0 else "?"


def service_state(name):
    # is-active returns non-zero when not active; both stdout and exit are
    # informative, so swallow CalledProcessError instead of capture_output.
    r = run(["systemctl", "is-active", name])
    return r.stdout.strip() or "unknown"


def status():
    return {
        "sirepo_rev":     git_rev("/opt/sirepo"),
        "pykern_rev":     git_rev("/opt/pykern"),
        "sirepo_active":  service_state(SIREPO_SVC),
    }


def do_update():
    log = []
    # git pull both repos
    for repo in ("/opt/pykern", "/opt/sirepo"):
        r = run(["git", "-C", repo, "pull", "--ff-only"])
        log.append(f"== git pull {repo} (exit {r.returncode}) ==\n{r.stdout}{r.stderr}")
        if r.returncode != 0:
            return False, "".join(log)
    # editable pip install (no-op when versions match, fast when they do)
    for repo in ("/opt/pykern", "/opt/sirepo"):
        r = run([VENV_PIP, "install", "-e", repo])
        # pip's output is verbose; tail it.
        log.append(f"== pip install -e {repo} (exit {r.returncode}) ==\n{r.stderr[-2000:]}")
        if r.returncode != 0:
            return False, "".join(log)
    # restart sirepo so the new code is loaded
    r = run(["systemctl", "restart", SIREPO_SVC])
    log.append(f"== systemctl restart {SIREPO_SVC} (exit {r.returncode}) ==\n{r.stdout}{r.stderr}")
    return r.returncode == 0, "".join(log)


def do_sbatch_creds(data):
    host = (data.get("host") or "").strip()
    user = (data.get("user") or "").strip()
    password = data.get("password") or ""
    if not (host and user):
        return False, "host and user are required"
    os.makedirs(os.path.dirname(SBATCH_ENV), exist_ok=True)
    lines = [
        f"SIREPO_JOB_DRIVER_SBATCH_HOST={host}",
        f"SIREPO_JOB_DRIVER_SBATCH_USER={user}",
    ]
    if password:
        lines.append(f"SIREPO_JOB_DRIVER_SBATCH_PASSWORD={password}")
    # Restrictive perms: this file holds a cleartext password if provided.
    fd = os.open(SBATCH_ENV, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")
    r = run(["systemctl", "restart", SIREPO_SVC])
    return r.returncode == 0, f"wrote {SBATCH_ENV}; restart exit={r.returncode}\n{r.stderr}"


def do_restart():
    r = run(["systemctl", "restart", SIREPO_SVC])
    return r.returncode == 0, r.stdout + r.stderr


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if not length:
            return {}
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/status":
            return self._send(200, status())
        self._send(404, {"error": f"unknown path {path}"})

    def do_POST(self):
        path = urlparse(self.path).path
        data = self._read_json()
        if data is None:
            return self._send(400, {"error": "body is not valid JSON"})

        if path == "/update":
            ok, log = do_update()
            return self._send(200 if ok else 500,
                              {"ok": ok, "log": log, "status": status()})
        if path == "/sbatch_creds":
            ok, log = do_sbatch_creds(data)
            return self._send(200 if ok else 400,
                              {"ok": ok, "log": log, "status": status()})
        if path == "/restart":
            ok, log = do_restart()
            return self._send(200 if ok else 500,
                              {"ok": ok, "log": log, "status": status()})
        self._send(404, {"error": f"unknown path {path}"})

    def log_message(self, fmt, *args):
        # Default access log goes to stderr -> journalctl -u sirepo-control.
        # Drop the timestamp prefix; systemd adds its own.
        sys.stderr.write(fmt % args + "\n")


def main():
    port = int(os.environ.get("SIREPO_CONTROL_PORT", "8312"))
    httpd = http.server.HTTPServer(("0.0.0.0", port), Handler)
    print(f"sirepo-control listening on 0.0.0.0:{port}", file=sys.stderr)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
