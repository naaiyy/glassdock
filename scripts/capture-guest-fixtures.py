#!/usr/bin/env python3
"""Captures golden fixtures from a live guest agent over vsock.

Speaks the control protocol directly against the agent's vsock unix socket
(host side of krun_add_vsock_port2 port 1025): each frame is a big-endian
uint32 length prefix followed by a JSON envelope:

    {"id": 1, "kind": "request", "method": "...", "payload": {...}}

Only read-only methods are captured. Fixtures land in
Tests/Fixtures/Guest/<name>.json as raw response payloads.

Usage:
    scripts/capture-guest-fixtures.py /tmp/glassdock-vmm-<uuid>/vsock/1025.sock \
        [--out Tests/Fixtures/Guest]
"""

import argparse
import json
import socket
import struct
import sys
import time

METHODS = ["ping", "version", "network.list", "container.list", "image.list"]
READ_TIMEOUT = 20.0


def send_request(sock, request_id, method):
    frame = {
        "id": request_id,
        "kind": "request",
        "method": method,
        "payload": {},
    }
    data = json.dumps(frame).encode()
    sock.sendall(struct.pack(">I", len(data)) + data)


def read_frame(sock):
    header = b""
    while len(header) < 4:
        chunk = sock.recv(4 - len(header))
        if not chunk:
            raise ConnectionError("guest closed the connection")
        header += chunk
    length = struct.unpack(">I", header)[0]
    if length == 0 or length > 16 * 1024 * 1024:
        raise ValueError(f"invalid frame length {length}")
    payload = b""
    while len(payload) < length:
        chunk = sock.recv(length - len(payload))
        if not chunk:
            raise ConnectionError("guest closed mid-frame")
        payload += chunk
    return json.loads(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("socket", help="path to the agent's host-side vsock socket")
    parser.add_argument("--out", default="Tests/Fixtures/Guest")
    args = parser.parse_args()

    failures = []
    for method in METHODS:
        name = method.replace(".", "-")
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(READ_TIMEOUT)
            sock.connect(args.socket)
            send_request(sock, request_id=1, method=method)
            deadline = time.monotonic() + READ_TIMEOUT
            while True:
                frame = read_frame(sock)
                if time.monotonic() > deadline:
                    raise TimeoutError(method)
                if frame.get("kind") != "response":
                    continue
                if frame.get("error"):
                    raise ValueError(f"{method}: {frame['error']}")
                break
            payload = frame.get("payload")
            if not isinstance(payload, dict):
                raise ValueError(f"{method}: response payload is not an object")
            out = f"{args.out}/{name}.json"
            with open(out, "w") as handle:
                json.dump(payload, handle, indent=2, sort_keys=True)
                handle.write("\n")
            print(f"captured {method} -> {out} ({len(json.dumps(payload))} bytes)")
            sock.close()
        except Exception as error:  # noqa: BLE001 - report and continue
            failures.append(f"{method}: {error}")
            print(f"FAILED {method}: {error}", file=sys.stderr)

    if failures:
        sys.exit(1)


if __name__ == "__main__":
    main()
