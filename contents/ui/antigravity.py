#!/usr/bin/env python3
# based on @levitycheck.py by Tract0r <@cornfields>

import json
import platform
import re
import ssl
import subprocess
import sys
from datetime import datetime, timezone
from http.client import HTTPSConnection, HTTPConnection
import socket

def run_cmd(cmd):
    result = subprocess.run(
        cmd,
        shell=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout, result.stderr, result.returncode

def get_process_info_linux():
    process_name = (
        "language_server_linux_arm" if platform.machine() == "arm64" else
        "language_server_linux_x64"
    )
    cmd = f"pgrep -af {process_name}"
    stdout, stderr, code = run_cmd(cmd)
    for line in stdout.splitlines():
        if "--extension_server_port" in line:
            parts = line.strip().split()
            pid = int(parts[0])
            cmdline = line[len(parts[0]):].strip()
            port_match = re.search(r"--extension_server_port[=\s]+(\d+)", cmdline)
            token_match = re.search(r"--csrf_token[=\s]+([a-zA-Z0-9\-]+)", cmdline)
            return {
                "pid": pid,
                "extension_port": int(port_match.group(1)) if port_match else 0,
                "csrf_token": token_match.group(1) if token_match else "",
            }
    return None

def get_listening_ports_unix(pid):
    ports = set()
    ss_cmd = f"ss -tlnp 2>/dev/null | grep \"pid={pid}\""
    stdout, stderr, code = run_cmd(ss_cmd)
    ss_regex = re.compile(r"LISTEN\s+\d+\s+\d+\s+(?:\*|[\d.]+|\[[\da-f:]*\]):(\d+).*?pid=%d" % pid, re.I)
    for m in ss_regex.finditer(stdout):
        ports.add(int(m.group(1)))

    if not ports:
        lsof_cmd = f"lsof -nP -a -iTCP -sTCP:LISTEN -p {pid} 2>/dev/null"
        stdout, stderr, code = run_cmd(lsof_cmd)
        lsof_regex = re.compile(r"^\S+\s+%d\s+.*?(?:TCP|UDP)\s+(?:\*|[\d.]+|\[[\da-f:]+\]):(\d+)\s+\(LISTEN\)" % pid, re.I | re.M)
        for m in lsof_regex.finditer(stdout):
            ports.add(int(m.group(1)))

    return sorted(ports)

def request_json(port, path, token, body, use_https=True):
    data = json.dumps(body).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Content-Length": str(len(data)),
        "Connect-Protocol-Version": "1",
        "X-Codeium-Csrf-Token": token,
    }

    if use_https:
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        conn = HTTPSConnection("127.0.0.1", port, context=context, timeout=5)
    else:
        conn = HTTPConnection("127.0.0.1", port, timeout=5)

    try:
        conn.request("POST", path, body=data, headers=headers)
        resp = conn.getresponse()
        resp_body = resp.read().decode("utf-8", errors="replace")
        return resp.status, resp_body
    finally:
        conn.close()

def find_working_port(ports, token):
    for port in ports:
        for use_https in (True, False):
            try:
                status, body = request_json(
                    port,
                    "/exa.language_server_pb.LanguageServerService/GetUnleashData",
                    token,
                    {"wrapper_data": {}},
                    use_https=use_https,
                )
            except (ssl.SSLError, OSError, socket.error):
                continue
            if status == 200:
                try:
                    json.loads(body)
                    return port, use_https
                except Exception:
                    pass
    return None, None

def main():
    if sys.platform != "linux":
        print(json.dumps({"error": "Unsupported OS"}))
        return

    info = get_process_info_linux()
    if not info:
        print(json.dumps({"error": "Antigravity process not found"}))
        return

    token = info.get("csrf_token", "")
    ports = get_listening_ports_unix(info["pid"])
    
    if not ports:
        print(json.dumps({"error": "No listening ports found"}))
        return

    port, use_https = find_working_port(ports, token)
    if not port:
        print(json.dumps({"error": "No working port found"}))
        return

    status, body = request_json(
        port,
        "/exa.language_server_pb.LanguageServerService/GetUserStatus",
        token,
        {"metadata": {"ideName": "antigravity", "extensionName": "antigravity", "locale": "en"}},
        use_https=use_https,
    )

    if status != 200:
        print(json.dumps({"error": f"API request failed: {status}"}))
        return

    try:
        data = json.loads(body)
        user = data.get("userStatus", {})
        models = user.get("cascadeModelConfigData", {}).get("clientModelConfigs", [])
        
        result_models = []
        for model in models:
            quota = model.get("quotaInfo") or {}
            remaining_fraction = quota.get("remainingFraction")
            
            # Treat None or missing as 0 (depleted)
            if remaining_fraction is None:
                remaining_fraction = 0.0
                
            label = model.get("label", "Unknown")
            reset_time = quota.get("resetTime")
            
            result_models.append({
                "name": label,
                "remaining": remaining_fraction * 100.0,
                "reset": reset_time
            })
            
        print(json.dumps({"models": result_models}))
        
    except Exception as e:
        print(json.dumps({"error": f"JSON parse error: {str(e)}"}))

if __name__ == "__main__":
    main()
