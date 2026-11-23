import json
import subprocess
import sys
import threading
import time
import unittest
import urllib.request
from http.server import HTTPServer
from unittest.mock import patch

from diagnostic_service import Collector, handler_for, parse_sample, read_ssh

CONFIG = {'ssh_config': '/test/config', 'nodes': [{'node_id': 'router-a', 'name': 'A', 'alias': 'a'}, {'node_id': 'router-b', 'name': 'B', 'alias': 'b'}]}


def sample(**changes):
    value = {'version': 1, 'interval_seconds': 60, 'timestamp': int(time.time()), 'wan_up': True, 'probes': [], 'nps_running': True, 'dns_ok': True, 'wan_outages_24h': 0, 'observation_seconds_24h': 120}
    value.update(changes)
    return json.dumps(value).encode()


class DiagnosticTests(unittest.TestCase):
    def test_unknown_is_not_reported_as_down_and_coverage_is_real(self):
        result = parse_sample(sample(wan_up=None, dns_ok=None, observation_seconds_24h=7), time.time())
        self.assertIsNone(result['wan_up'])
        self.assertIsNone(result['dns_ok'])
        self.assertEqual(result['observation_seconds_24h'], 7)

    def test_invalid_samples_are_rejected(self):
        probe = {'id': 'ping', 'label': 'Target', 'kind': 'icmp', 'target': '192.0.2.1', 'ok': True}
        bad = [b'[]', sample(version=True), sample(timestamp=True), sample(timestamp=0), sample(timestamp=float('nan')), sample(timestamp=int(time.time())+400), sample(interval_seconds=10**30), sample(wan_up='true'), sample(dns_ok=1), sample(nps_running=None), sample(observation_seconds_24h=True), sample(observation_seconds_24h=-1), sample(observation_seconds_24h=86401), sample(wan_outages_24h=-1), sample(probes=[None]), sample(probes=[probe, probe]), sample(probes=[dict(probe, latency_ms=-1)]), sample(probes=[dict(probe, latency_ms=float('inf'))]), sample(probes=[dict(probe, loss_percent=101)]), sample(probes=[dict(probe, loss_percent=True)])]
        for raw in bad:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                parse_sample(raw, time.time())

    def test_repeated_failures_keep_last_sample_without_claiming_online(self):
        collector = Collector(CONFIG, reader=lambda *_: sample())
        collector.refresh()
        stamp = collector.snapshot()['nodes']['router-a']['timestamp']
        def unavailable(*_):
            raise OSError('offline')
        collector.reader = unavailable
        collector.refresh()
        collector.refresh()
        with patch('diagnostic_service.time.time', return_value=stamp+500):
            result = collector.snapshot()['nodes']['router-a']
        self.assertEqual(result['status'], 'unavailable')
        self.assertEqual(result['last_sample']['timestamp'], stamp)
        self.assertEqual(result['last_sample']['status'], 'stale')
        self.assertEqual(result['last_sample']['age_seconds'], 500)

    def test_partial_loss_is_retained_without_becoming_a_failed_probe(self):
        probe = {'id': 'partial', 'label': 'VPS', 'kind': 'ping', 'target': '192.0.2.1', 'ok': True, 'loss_percent': 50}
        probes = [probe, dict(probe, id='good', loss_percent=0),
                  dict(probe, id='down', ok=False, loss_percent=100),
                  dict(probe, id='ssh', kind='ssh', loss_percent=None),
                  dict(probe, id='unknown', ok=None, loss_percent=None)]
        result = parse_sample(sample(probes=probes), time.time())
        self.assertEqual([p['id'] for p in result['failed_probes']], ['down'])
        self.assertEqual([p['id'] for p in result['degraded_probes']], ['partial'])
        self.assertEqual(result['degraded_probes'][0]['loss_percent'], 50)
        self.assertNotIn('target', result['degraded_probes'][0])
        self.assertEqual(result['status'], 'ok')

    def test_http_returns_immediately_during_parallel_initial_reads(self):
        barrier = threading.Barrier(3)
        release = threading.Event()
        stop = threading.Event()
        def blocked(*_):
            barrier.wait(timeout=2)
            release.wait(timeout=2)
            return sample()
        collector = Collector(CONFIG, reader=blocked)
        server = HTTPServer(('127.0.0.1', 0), handler_for(collector))
        http_thread = threading.Thread(target=server.serve_forever, daemon=True)
        http_thread.start()
        poll_thread = collector.start(stop)
        try:
            barrier.wait(timeout=2)
            started = time.monotonic()
            data = json.load(urllib.request.urlopen('http://127.0.0.1:%d/diagnostic' % server.server_port, timeout=0.5))
            self.assertLess(time.monotonic()-started, 0.5)
            self.assertEqual(data['nodes']['router-a']['reason'], 'initializing')
            self.assertEqual(data['nodes']['router-b']['status'], 'unavailable')
        finally:
            stop.set()
            release.set()
            poll_thread.join(timeout=3)
            server.shutdown()
            server.server_close()
            http_thread.join(timeout=1)

    def test_snapshot_ages_even_when_no_new_refresh_runs(self):
        collector = Collector(CONFIG, reader=lambda *_: sample())
        collector.refresh()
        stamp = collector.snapshot()['nodes']['router-a']['timestamp']
        with patch('diagnostic_service.time.time', return_value=stamp+181):
            self.assertEqual(collector.snapshot()['nodes']['router-a']['status'], 'stale')
        with patch('diagnostic_service.time.time', return_value=stamp+40):
            self.assertEqual(collector.snapshot()['nodes']['router-a']['age_seconds'], 40)

    def test_ssh_output_and_duration_are_bounded(self):
        popen = subprocess.Popen
        with patch('diagnostic_service.subprocess.Popen', side_effect=lambda *_, **kw: popen([sys.executable, '-c', 'print("x" * 2097152)'], **kw)):
            with self.assertRaises(ValueError):
                read_ssh(CONFIG, CONFIG['nodes'][0])
        with patch('diagnostic_service.SSH_TIMEOUT', 0.15), patch('diagnostic_service.subprocess.Popen', side_effect=lambda *_, **kw: popen([sys.executable, '-c', 'import time; time.sleep(5)'], **kw)):
            started = time.monotonic()
            with self.assertRaises(TimeoutError):
                read_ssh(CONFIG, CONFIG['nodes'][0])
            self.assertLess(time.monotonic()-started, 1)


if __name__ == '__main__':
    unittest.main()
