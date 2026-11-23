#!/usr/bin/env python3
"""Loopback-only cache of bounded, read-only router health samples."""
import copy
import json
import math
import os
import re
import subprocess
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer

COMMAND = "cat /tmp/vpsmonitor-network/latest.json"
MAX_BYTES = 1_048_576
SSH_TIMEOUT = 15


def integer(value, low, high):
    return type(value) is int and low <= value <= high


def tri_state(value):
    return value is None or type(value) is bool


def bounded_text(value, limit):
    return isinstance(value, str) and len(value) <= limit


def finite_number(value, low, high):
    return type(value) in (int, float) and math.isfinite(value) and low <= value <= high


def sample_age(sample, now):
    sample["age_seconds"] = max(0, int(now - sample["timestamp"]))
    if sample["status"] in ("ok", "stale"):
        sample["status"] = "stale" if sample["age_seconds"] > max(180, sample["interval_seconds"] * 3) else "ok"


def parse_sample(raw, now):
    if len(raw) > MAX_BYTES:
        raise ValueError("output_too_large")
    sample = json.loads(raw)
    if not isinstance(sample, dict):
        raise ValueError("sample_not_object")
    if not integer(sample.get("version"), 1, 1) or not integer(sample.get("timestamp"), 1, int(now) + 300):
        raise ValueError("invalid_version_or_timestamp")
    if not integer(sample.get("interval_seconds"), 30, 600):
        raise ValueError("invalid_interval")
    if sample.get("observed_since") is not None and not integer(sample["observed_since"], 1, sample["timestamp"]):
        raise ValueError("invalid_observed_since")
    if not tri_state(sample.get("wan_up")) or type(sample.get("nps_running")) is not bool or not tri_state(sample.get("dns_ok")):
        raise ValueError("invalid_state")
    if not integer(sample.get("wan_outages_24h"), 0, 86_400) or not integer(sample.get("observation_seconds_24h"), 0, 86_400):
        raise ValueError("invalid_coverage")
    probes = sample.get("probes")
    if not isinstance(probes, list) or len(probes) > 64:
        raise ValueError("invalid_probes")
    ids = set()
    for probe in probes:
        if not isinstance(probe, dict):
            raise ValueError("invalid_probe")
        if not bounded_text(probe.get("id"), 128) or not probe["id"] or probe["id"] in ids:
            raise ValueError("invalid_probe_id")
        ids.add(probe["id"])
        if not all(bounded_text(probe.get(key), limit) for key, limit in (("label", 128), ("kind", 32), ("target", 256))):
            raise ValueError("invalid_probe_text")
        if not tri_state(probe.get("ok")):
            raise ValueError("invalid_probe_state")
        if probe.get("error") is not None and not bounded_text(probe["error"], 1024):
            raise ValueError("invalid_probe_error")
        for key, upper in (("latency_ms", 3_600_000), ("loss_percent", 100)):
            if probe.get(key) is not None and not finite_number(probe[key], 0, upper):
                raise ValueError("invalid_probe_metric")
    result = {key: sample.get(key) for key in ("timestamp", "interval_seconds", "wan_up", "nps_running", "dns_ok", "wan_outages_24h", "observation_seconds_24h")}
    fields = ("id", "label", "kind", "loss_percent")
    result.update(
        status="ok",
        failed_probes=[{key: probe.get(key) for key in fields} for probe in probes if probe.get("ok") is False],
        degraded_probes=[{key: probe.get(key) for key in fields} for probe in probes
                         if probe.get("ok") is True and probe.get("loss_percent") is not None
                         and 0 < probe["loss_percent"] < 100],
    )
    sample_age(result, now)
    return result


def read_ssh(config, node):
    arguments = ["/usr/bin/ssh", "-T", "-F", config["ssh_config"], "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8", "-o", "ConnectionAttempts=1", "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1", "--", node["alias"], COMMAND]
    with tempfile.TemporaryFile() as output:
        process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + SSH_TIMEOUT
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError("ssh_timeout")
                if os.fstat(output.fileno()).st_size > MAX_BYTES:
                    raise ValueError("output_too_large")
                time.sleep(0.05)
            if process.returncode:
                raise OSError("ssh_failed")
            output.seek(0)
            raw = output.read(MAX_BYTES + 1)
            if len(raw) > MAX_BYTES:
                raise ValueError("output_too_large")
            return raw
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()


class Collector:
    def __init__(self, config, reader=read_ssh):
        self.config, self.reader = config, reader
        self.lock = threading.Lock()
        self.cache = {"generated_at": int(time.time()), "nodes": {node["node_id"]: {"name": node["name"], "status": "unavailable", "reason": "initializing"} for node in config["nodes"]}}

    def read(self, node):
        try:
            return parse_sample(self.reader(self.config, node), time.time())
        except (ValueError, UnicodeError):
            return {"status": "invalid", "reason": "invalid_sample"}
        except (OSError, TimeoutError):
            return {"status": "unavailable", "reason": "ssh_unavailable"}

    def refresh(self):
        nodes = self.config["nodes"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = dict(zip((node["node_id"] for node in nodes), pool.map(self.read, nodes)))
        with self.lock:
            previous = self.cache["nodes"]
            for node in nodes:
                result = results[node["node_id"]]
                result["name"] = node["name"]
                old = previous.get(node["node_id"], {})
                if result["status"] not in ("ok", "stale"):
                    last = old if old.get("status") in ("ok", "stale") else old.get("last_sample")
                    if last:
                        result["last_sample"] = copy.deepcopy(last)
            self.cache = {"generated_at": int(time.time()), "nodes": results}

    def snapshot(self):
        with self.lock:
            result = copy.deepcopy(self.cache)
        now = time.time()
        for node in result["nodes"].values():
            if "timestamp" in node:
                sample_age(node, now)
            if node.get("last_sample"):
                sample_age(node["last_sample"], now)
        return result

    def start(self, stop, interval=60):
        def loop():
            while not stop.is_set():
                started = time.monotonic()
                self.refresh()
                stop.wait(max(0, interval - (time.monotonic() - started)))
        thread = threading.Thread(target=loop, daemon=True)
        thread.start()
        return thread


def handler_for(collector):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/diagnostic":
                self.send_error(404)
                return
            body = json.dumps(collector.snapshot(), ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            pass
    return Handler


def load(path):
    with open(path, encoding="utf-8") as source:
        config = json.load(source)
    if not isinstance(config, dict) or not isinstance(config.get("ssh_config"), str) or not os.path.isabs(config["ssh_config"]):
        raise ValueError("invalid SSH config path")
    nodes = config.get("nodes")
    if not isinstance(nodes, list) or not 1 <= len(nodes) <= 2:
        raise ValueError("expected one or two routers")
    ids = set()
    for node in nodes:
        if not isinstance(node, dict) or set(node) != {"node_id", "alias", "name"}:
            raise ValueError("invalid router config")
        if not bounded_text(node["node_id"], 128) or not node["node_id"] or node["node_id"] in ids:
            raise ValueError("invalid node ID")
        if not isinstance(node["alias"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", node["alias"]) or not bounded_text(node["name"], 128):
            raise ValueError("invalid router alias or name")
        ids.add(node["node_id"])
    return config


def main():
    collector = Collector(load(os.environ.get("NETWORK_DIAGNOSTIC_CONFIG", "/etc/vpsmonitor/network-diagnostic.json")))
    server = HTTPServer(("127.0.0.1", 18765), handler_for(collector))
    stop = threading.Event()
    collector.start(stop)
    try:
        server.serve_forever()
    finally:
        stop.set()
        server.server_close()


if __name__ == "__main__":
    main()
