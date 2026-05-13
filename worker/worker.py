r"""
Sirepo_Win native-Windows SRW worker.

Receives compute jobs from the Sirepo job supervisor inside the Linux backend
(WSL2 or QEMU/TCG) over HTTP and runs them under native CPython with native
srwpy. The point is to dodge the 10-50x TCG slowdown for QEMU users and to
keep the WSL2 /mnt/c filesystem out of the hot loop.

Also serves the project tree to the QEMU VM via WebDAV under /dav/, so a
QEMU guest with no Windows-side virtfs can still get an editable Sirepo
install. The VM mounts http://10.0.2.2:<port>/dav/ via davfs2 at boot.
WSL2 has /mnt/c directly so doesn't need the /dav route.

Endpoints
---------
GET /health
    Liveness + srwpy probe. Reports srwlib module path so callers can
    distinguish a healthy worker from one that loaded the wrong Python.

POST /run
    Execute a command in a run dir on the native Windows side. Body:
        {
          "run_dir":   "/mnt/c/Users/.../runs/srw/<jid>",   # Linux path
          "cmd":       ["python", "run.py"],                # argv; first
                                                            # element "python"
                                                            # is rewritten to
                                                            # python-native.
          "timeout_s": 1800                                 # optional
        }
    Returns:
        {
          "returncode": 0,
          "stdout":     "...",
          "stderr":     "...",
          "run_dir_win":"C:\\Users\\...\\runs\\srw\\<jid>",
          "duration_s": 1.42
        }

/dav/...
    WebDAV view of WEBDAV_ROOT (defaults to the project root -- the parent
    of worker/). Read/write so `pip install -e` from the VM can land its
    *.egg-info on the Windows side. Anonymous auth (loopback-only exposure).

The driver in the Linux env hands us a Linux path; we translate it to a
Windows path via the WORKER_PATH_MAP env var (linux_prefix=windows_prefix
pairs, comma-separated). Default map: /mnt/c -> C:\. The QEMU mount adds
/mnt/host-src -> <project root> automatically (see scripts/run-worker.ps1).
"""
from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path, PureWindowsPath
from typing import Any

import uvicorn
from a2wsgi import WSGIMiddleware
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from wsgidav.wsgidav_app import WsgiDAVApp

# Probe srwpy at import time so /health can report version + truthful status.
_SRWPY_INFO: dict[str, Any] = {"loaded": False}
try:
    from srwpy import srwlib  # type: ignore

    _SRWPY_INFO = {"loaded": True, "module_path": srwlib.__file__}
except Exception as e:
    _SRWPY_INFO = {"loaded": False, "error": f"{type(e).__name__}: {e}"}


# Path translation. Default maps Linux /mnt/<drive>/<rest> to <DRIVE>:\<rest>.
# Override with WORKER_PATH_MAP="<linux>=<windows>,<linux>=<windows>".
def _default_path_map() -> list[tuple[str, str]]:
    return [(f"/mnt/{c}", f"{c.upper()}:\\") for c in "abcdefghijklmnopqrstuvwxyz"]


def _parse_path_map(raw: str | None) -> list[tuple[str, str]]:
    if not raw:
        return _default_path_map()
    pairs = []
    for item in raw.split(","):
        if "=" not in item:
            continue
        l, w = item.split("=", 1)
        pairs.append((l.rstrip("/"), w.rstrip("\\")))
    # Longest prefix wins so /mnt/projectshare beats /mnt/p.
    pairs.sort(key=lambda x: -len(x[0]))
    return pairs + _default_path_map()


PATH_MAP = _parse_path_map(os.environ.get("WORKER_PATH_MAP"))

# python-native interpreter to use when cmd[0] == "python". Default is the one
# this worker is running under; override via WORKER_PYTHON.
WORKER_PYTHON = os.environ.get("WORKER_PYTHON") or sys.executable


def translate_path(linux_path: str) -> str:
    """Map /mnt/c/foo/bar -> C:\\foo\\bar (or per PATH_MAP)."""
    p = linux_path.replace("\\", "/")
    for linux_prefix, win_prefix in PATH_MAP:
        if p == linux_prefix or p.startswith(linux_prefix + "/"):
            rest = p[len(linux_prefix):].lstrip("/")
            win_path = PureWindowsPath(win_prefix) / rest if rest else PureWindowsPath(win_prefix)
            return str(win_path)
    raise ValueError(
        f"No path-map entry covers {linux_path!r}. "
        f"Configured prefixes: {[p[0] for p in PATH_MAP[:5]]}..."
    )


app = FastAPI(title="Sirepo_Win native worker", version="0.3.0")
_started_at = time.time()


# WebDAV view of the project tree (defaults to parent of worker/, i.e. the
# Sirepo_Win project root). Mounted under /dav in the FastAPI app so a single
# Python process handles both /run and /dav.
WEBDAV_ROOT = os.path.abspath(
    os.environ.get("WEBDAV_ROOT") or os.path.join(os.path.dirname(__file__), "..")
)


def _build_webdav_app() -> WsgiDAVApp:
    """Anonymous, read-write WebDAV exposing WEBDAV_ROOT at /dav/.

    Anonymous because we bind 127.0.0.1; QEMU slirp NATs 10.0.2.2->host so the
    guest reaches us without auth. Read-write so `pip install -e` can write
    *.egg-info back into the Windows source tree from inside the VM.
    """
    config = {
        "host": "0.0.0.0",  # ignored when mounted as sub-app
        "port": 0,
        "provider_mapping": {"/": WEBDAV_ROOT},
        "http_authenticator": {
            "domain_controller": None,  # use simple_dc below
            "accept_basic": True,
            "accept_digest": False,
            "default_to_digest": False,
        },
        "simple_dc": {"user_mapping": {"*": True}},  # anonymous allowed for everything
        "verbose": 1,
        "logging": {"enable_loggers": []},
        "property_manager": True,
        "lock_storage": True,
        "dir_browser": {"enable": True, "response_trailer": "Sirepo_Win worker WebDAV"},
    }
    return WsgiDAVApp(config)


app.mount("/dav", WSGIMiddleware(_build_webdav_app()))


class RunRequest(BaseModel):
    run_dir: str
    cmd: list[str] = ["python", "run.py"]
    timeout_s: float = 1800.0


class RunResponse(BaseModel):
    returncode: int
    stdout: str
    stderr: str
    run_dir_win: str
    duration_s: float


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "uptime_s": round(time.time() - _started_at, 2),
        "python": sys.version.split()[0],
        "python_exe": WORKER_PYTHON,
        "platform": platform.platform(),
        "srwpy": _SRWPY_INFO,
        "path_map_prefixes": [p[0] for p in PATH_MAP[:5]],
        "webdav_root": WEBDAV_ROOT,
        "pid": os.getpid(),
    }


@app.post("/run", response_model=RunResponse)
def run(req: RunRequest) -> RunResponse:
    try:
        win_dir = translate_path(req.run_dir)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    if not os.path.isdir(win_dir):
        raise HTTPException(
            status_code=404,
            detail=f"run_dir does not exist on Windows side: {win_dir} (from {req.run_dir!r})",
        )

    if not req.cmd:
        raise HTTPException(status_code=400, detail="cmd must be non-empty")

    argv = list(req.cmd)
    if argv[0].lower() in ("python", "python.exe", "python3"):
        argv[0] = WORKER_PYTHON

    t0 = time.time()
    try:
        proc = subprocess.run(
            argv,
            cwd=win_dir,
            capture_output=True,
            text=True,
            timeout=req.timeout_s,
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=400, detail=f"executable not found: {e}")
    except subprocess.TimeoutExpired as e:
        raise HTTPException(
            status_code=504,
            detail=f"job exceeded timeout_s={req.timeout_s}: {e}",
        )
    return RunResponse(
        returncode=proc.returncode,
        stdout=proc.stdout,
        stderr=proc.stderr,
        run_dir_win=win_dir,
        duration_s=round(time.time() - t0, 3),
    )


def main() -> None:
    p = argparse.ArgumentParser()
    # Bind loopback by default. QEMU slirp NATs the guest's 10.0.2.2 traffic to
    # the host's 127.0.0.1 (slirp `host_addr` default is loopback), so the VM
    # can reach us without needing 0.0.0.0 and the firewall-rule song-and-dance
    # that goes with it. Override to 0.0.0.0 if you also need WSL2 / LAN access.
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8311)
    args = p.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
