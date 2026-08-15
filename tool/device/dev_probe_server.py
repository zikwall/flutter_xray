#!/usr/bin/env python3
"""Ephemeral HTTP, UDP echo and DNS observation server for a dev contour."""

from __future__ import annotations

import argparse
import http.server
import ipaddress
import socket
import struct
import threading
import urllib.parse


class ProbeState:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.dns_sources: dict[str, str] = {}

    def record_dns(self, hostname: str, source: str) -> None:
        with self.lock:
            self.dns_sources[hostname] = source

    def dns_source(self, hostname: str) -> str | None:
        with self.lock:
            return self.dns_sources.get(hostname)


def parse_dns_question(data: bytes) -> tuple[str, int]:
    offset = 12
    labels: list[str] = []
    while offset < len(data):
        length = data[offset]
        offset += 1
        if length == 0:
            break
        if length & 0xC0 or offset + length > len(data):
            raise ValueError("unsupported DNS question")
        labels.append(data[offset : offset + length].decode("ascii"))
        offset += length
    if offset + 4 > len(data):
        raise ValueError("truncated DNS question")
    return ".".join(labels), offset + 4


def dns_response(query: bytes, answer_ipv4: str) -> tuple[str, bytes]:
    if len(query) < 12:
        raise ValueError("truncated DNS packet")
    hostname, question_end = parse_dns_question(query)
    header = query[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
    question = query[12:question_end]
    answer = (
        b"\xc0\x0c"
        + struct.pack("!HHIH", 1, 1, 30, 4)
        + ipaddress.IPv4Address(answer_ipv4).packed
    )
    return hostname, header + question + answer


def udp_echo(bind: str, port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind((bind, port))
        while True:
            payload, peer = server.recvfrom(65535)
            server.sendto(payload, peer)


def dns_probe(
    bind: str,
    port: int,
    answer_ipv4: str,
    state: ProbeState,
) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
        server.bind((bind, port))
        while True:
            query, peer = server.recvfrom(4096)
            try:
                hostname, response = dns_response(query, answer_ipv4)
            except (UnicodeDecodeError, ValueError):
                continue
            state.record_dns(hostname, peer[0])
            server.sendto(response, peer)


def handler(state: ProbeState, max_payload: int):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
            parsed = urllib.parse.urlparse(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            if parsed.path == "/healthz":
                self._reply(b"ok\n")
                return
            if parsed.path == "/ip":
                self._reply(f"{self.client_address[0]}\n".encode())
                return
            if parsed.path == "/payload":
                requested = int(query.get("bytes", ["10000000"])[0])
                size = max(1, min(requested, max_payload))
                self._reply_payload(size)
                return
            if parsed.path == "/dns-source":
                hostname = query.get("hostname", [""])[0]
                source = state.dns_source(hostname)
                if source is None:
                    self.send_error(404, "DNS observation not found")
                    return
                self._reply(f"{source}\n".encode())
                return
            self.send_error(404)

        def _reply(self, body: bytes) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _reply_payload(self, size: int) -> None:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            chunk = b"x" * min(65536, size)
            remaining = size
            try:
                while remaining > 0:
                    length = min(len(chunk), remaining)
                    self.wfile.write(chunk[:length])
                    remaining -= length
            except (BrokenPipeError, ConnectionResetError):
                return

        def log_message(self, format: str, *args: object) -> None:
            return

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--http-port", type=int, default=19001)
    parser.add_argument("--udp-port", type=int, default=19000)
    parser.add_argument("--dns-bind", default="0.0.0.0")
    parser.add_argument("--dns-port", type=int, default=19053)
    parser.add_argument("--dns-answer", default="203.0.113.7")
    parser.add_argument("--max-payload", type=int, default=64_000_000)
    args = parser.parse_args()

    state = ProbeState()
    threading.Thread(
        target=udp_echo,
        args=(args.bind, args.udp_port),
        daemon=True,
    ).start()
    threading.Thread(
        target=dns_probe,
        args=(args.dns_bind, args.dns_port, args.dns_answer, state),
        daemon=True,
    ).start()
    server = http.server.ThreadingHTTPServer(
        (args.bind, args.http_port),
        handler(state, args.max_payload),
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
