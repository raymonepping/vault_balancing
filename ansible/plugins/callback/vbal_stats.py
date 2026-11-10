# Adapted from golden_ticket (GPLv3).
"""Write only the play recap counts of a vault_balancing phase to a JSON file.

Never task results, never variables: one row per host with ok / changed /
failures / unreachable / skipped / rescued / ignored, plus the phase name,
whether it ran in check mode, and when. `make idempotency` and `make drift`
read these files; so does the console's Layers page (via .build/layers.json).
"""

from __future__ import annotations

DOCUMENTATION = """
name: vbal_stats
type: aggregate
short_description: Write the play recap counts (only) of a vault_balancing phase
description:
  - At the end of a run, writes <VBAL_STATS_DIR>/<VBAL_PHASE>[.check].json with the
    per-host recap counts. Does nothing unless both variables are set (so the
    Terraform-run baseline writes nothing).
requirements:
  - enable in callbacks_enabled
"""

import datetime
import json
import os

from ansible import context
from ansible.plugins.callback import CallbackBase

COUNTERS = ("ok", "changed", "failures", "unreachable", "skipped", "rescued", "ignored")


def summarize(stats):
    """Per-host recap counts from an AggregateStats-like object."""
    hosts = {}
    for host in sorted(stats.processed):
        counts = stats.summarize(host)
        hosts[host] = {key: int(counts.get(key, 0)) for key in COUNTERS}
    return hosts


def write_stats(out_dir, phase, hosts, check_mode, now=None):
    """Write the stats file atomically; return its path."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    document = {
        "phase": phase,
        "check_mode": bool(check_mode),
        "finished_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "hosts": hosts,
        "changed_total": sum(h["changed"] for h in hosts.values()),
        "failed_total": sum(h["failures"] + h["unreachable"] for h in hosts.values()),
    }
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, f"{phase}{'.check' if check_mode else ''}.json")
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(document, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)
    return path


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "vbal_stats"
    CALLBACK_NEEDS_ENABLED = True

    def v2_playbook_on_stats(self, stats):
        phase = os.environ.get("VBAL_PHASE")
        out_dir = os.environ.get("VBAL_STATS_DIR")
        if not phase or not out_dir:
            return
        check_mode = bool(context.CLIARGS.get("check", False))
        write_stats(out_dir, phase, summarize(stats), check_mode)
