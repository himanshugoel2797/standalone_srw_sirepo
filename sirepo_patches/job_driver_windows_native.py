"""Sirepo_Win windows_native job driver -- STUB.

Routes SRW compute jobs to a native-Windows worker (under python-native/) so
srwpy runs at host speed instead of inside the Linux backend (WSL2 lxss or
QEMU/TCG). The driver lives inside Sirepo (which runs in the Linux env) and
talks HTTP to the worker on the host side of the VM/distro boundary.

This file is the stub. It inherits the full LocalDriver lifecycle so an agent
still launches and runs jobs locally in the Linux env. Step #5 swaps the local
agent for an HTTP-dispatched remote agent on the Windows side.

How to enable:
  export SIREPO_JOB_DRIVER_MODULES=local:windows_native
  export SIREPO_JOB_DRIVER_WINDOWS_NATIVE_WORKER_URL=http://10.0.2.2:8311
  # 10.0.2.2 = QEMU slirp host. For WSL2:
  #   $(ip route show default | awk '/^default/{print $3}')

QEMU backend sets these in sirepo.service (cloud-init); WSL2 backend's
run-sirepo.sh sets them before invoking sirepo.

:copyright: Copyright (c) 2026 RadiaSoft LLC.  All Rights Reserved.
:license: http://www.apache.org/licenses/LICENSE-2.0.html
"""

from pykern import pkconfig
from pykern.pkdebug import pkdlog
from sirepo.job_driver import local


class WindowsNativeDriver(local.LocalDriver):
    """Inherits LocalDriver lifecycle. Overrides _do_agent_start in step #5."""

    cfg = None

    @classmethod
    def init_class(cls, job_supervisor):
        # Reuse LocalDriver's cfg parsing (agent_starting_secs, slots,
        # supervisor_uri) and tack on our worker_url. pkconfig.init() is keyed
        # by class hierarchy, so calling super().init_class() gives us a fully
        # configured base class without re-declaring shared keys.
        super().init_class(job_supervisor)
        cls.cfg = pkconfig.init(
            worker_url=(
                "http://10.0.2.2:8311",
                str,
                "URL of the native-Windows worker (QEMU/slirp default; "
                "set to the WSL2 host IP for the WSL2 backend)",
            ),
        )
        pkdlog("{} initialized with worker_url={}", cls.__name__, cls.cfg.worker_url)
        return cls

    async def _do_agent_start(self, op):
        # STUB: still spawns a local agent. Step #5 replaces this with an
        # HTTP-dispatched remote agent on the Windows side.
        pkdlog("{} routing job to worker={} (stub: local agent for now)",
               self, self.cfg.worker_url)
        return await super()._do_agent_start(op)


CLASS = WindowsNativeDriver
