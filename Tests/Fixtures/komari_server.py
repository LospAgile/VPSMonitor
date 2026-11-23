"""Loopback-only Komari fixture: RPC includes a node omitted by WebSocket."""
import base64
import hashlib
import json
import struct
import time
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = {"polls": [], "ws_gets": 0, "catalog_reads": 0, "public_status": 200, "catalog_status": 200,
         "status_status": 200, "status_delay": 0, "authenticated": True, "theme_settings": {}, "record_reads": [], "record_requests": [], "ws_enabled": True, "ws_all": False,
         "catalog": {key: {"uuid": key, "name": key, "cpu_cores": 2, "mem_total": 2048, "disk_total": 8192}
                     for key in ["visible", "hidden"]}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def json_response(self, value, status=200):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/fixture":
            state.update(request)
            self.json_response({"ok": True})
            return
        method = request["method"]
        if method == "common:getNodes":
            state["catalog_reads"] += 1
            if state["catalog_status"] != 200:
                self.json_response({"error": "fixture"}, state["catalog_status"])
                return
            result = state.get("catalog_result", state["catalog"])
        elif method == "common:getMe":
            result = {"logged_in": state["authenticated"]}
        elif method == "common:getNodesLatestStatus":
            if state["status_status"] != 200:
                self.json_response({"error": "fixture"}, state["status_status"])
                return
            ids = request["params"]["uuids"]
            state["polls"].append(ids)
            count = len(state["polls"])
            hidden_cpu = 10 if count == 1 else 80 if count == 2 else 90
            result = {key: {"cpu": hidden_cpu if key == "hidden" else 5,
                            "ram": 512, "ram_total": 2048, "disk": 1024,
                            "disk_total": 8192, "online": True} for key in ids}
            if "status_result" in state:
                result = state["status_result"]
            if state["status_delay"]:
                time.sleep(state["status_delay"])
        elif method == "common:getRecords":
            task_id = request["params"]["task_id"]
            state["record_reads"].append(task_id)
            state["record_requests"].append(request["params"])
            if request["params"].get("hours") == 24 and state.get("history_status", 200) != 200:
                self.json_response({"error": "fixture history failure"}, state["history_status"])
                return
            history = request["params"].get("hours") == 24
            offsets = [23 * 3600, 12 * 3600, 0] if history else [0]
            result = {"records": [{"client": key, "task_id": task_id, "value": 35,
                                   "time": (datetime.now(timezone.utc) - timedelta(seconds=offset)).isoformat()}
                                  for key in state["catalog"] for offset in offsets],
                      "tasks": [{"id": task_id, "name": "线路 " + str(task_id), "interval": 60}]}
            if history and state.get("history_delay", 0):
                time.sleep(state["history_delay"])
        else:
            result = {}
        self.json_response({"jsonrpc": "2.0", "id": request["id"], "result": result})

    def do_GET(self):
        if self.path == "/fixture":
            self.json_response(state)
            return
        if self.path != "/api/clients":
            self.json_response({"status": "success", "data": {"theme_settings": state["theme_settings"]}}, state["public_status"])
            return
        if not state["ws_enabled"]:
            self.json_response({"error": "fixture"}, 503)
            return
        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.wfile.flush()
        try:
            while True:
                header = self.rfile.read(2)
                if len(header) != 2:
                    break
                opcode = header[0] & 15
                length = header[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                mask = self.rfile.read(4) if header[1] & 128 else None
                payload = self.rfile.read(length)
                if mask:
                    payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
                if opcode == 8:
                    break
                if opcode != 1:
                    continue
                state["ws_gets"] += 1
                ids = list(state["catalog"]) if state["ws_all"] else ["visible"]
                data = json.dumps({"status": "success", "data": {
                    "online": ids, "data": {key: {
                        "cpu": {"usage": 23}, "ram": {"total": 2048, "used": 512},
                        "disk": {"total": 8192, "used": 1024}} for key in ids}}}).encode()
                self.wfile.write(b"\x81\x7e" + struct.pack("!H", len(data)) + data)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
