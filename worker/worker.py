r"""
Sirepo_Win native-Windows SRW worker.

Receives compute jobs from the Sirepo job supervisor inside the Linux backend
(WSL2 or QEMU/TCG) over HTTP and runs them under native CPython with native
srwpy. The point is to dodge the 10-50x TCG slowdown for QEMU users and to
keep the WSL2 /mnt/c filesystem out of the hot loop.

This is the stub. /run is currently an echo + capability probe -- once the
windows_native Sirepo job driver lands, /run will accept a real job spec
(serialized run.py inputs + run dir) and dispatch to sirepo.template.srw.

Bind: 127.0.0.1:<port>, no auth (loopback only; the WSL2 / QEMU guest reaches
this via its host IP. We never bind 0.0.0.0).

Run: python-native\python.exe worker\worker.py --port 8311
"""
from __future__ import annotations

import argparse
import os
import platform
import sys
import time
from typing import Any

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel

# Probe srwpy at import time so /health can report the version + truthful status.
_SRWPY_INFO: dict[str, Any] = {"loaded": False}
try:
    from srwpy import srwlib  # type: ignore

    _SRWPY_INFO = {
        "loaded": True,
        "module_path": srwlib.__file__,
    }
except Exception as e:
    _SRWPY_INFO = {"loaded": False, "error": f"{type(e).__name__}: {e}"}


app = FastAPI(title="Sirepo_Win native worker", version="0.1.0")
_started_at = time.time()


class RunRequest(BaseModel):
    """Stub schema. Will grow into the real job-spec contract in build step #5."""

    sim_type: str
    payload: dict[str, Any] = {}


class RunResponse(BaseModel):
    received: RunRequest
    worker_pid: int
    note: str


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "uptime_s": round(time.time() - _started_at, 2),
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "srwpy": _SRWPY_INFO,
        "pid": os.getpid(),
    }


@app.post("/run", response_model=RunResponse)
def run(req: RunRequest) -> RunResponse:
    if req.sim_type != "srw":
        # The whole point is SRW. Other sirepo codes don't have native-Windows
        # backends; they stay inside the Linux env.
        return RunResponse(
            received=req,
            worker_pid=os.getpid(),
            note=f"sim_type='{req.sim_type}' not supported by native worker (srw only)",
        )
    return RunResponse(
        received=req,
        worker_pid=os.getpid(),
        note="stub: real SRW execution lands in build step #5",
    )


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8311)
    args = p.parse_args()
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
