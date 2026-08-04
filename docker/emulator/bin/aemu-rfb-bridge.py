#!/usr/bin/env python3
"""Expose AEMU's event-driven framebuffer and input streams as loopback RFB."""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import socket
import struct
import subprocess
import sys
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import BinaryIO


LOG = logging.getLogger("aemu-rfb-bridge")
CONTROLLER = "android.emulation.control.EmulatorController"
SERVER_PIXEL_FORMAT = struct.pack(">BBBBHHHBBBxxx", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
KEYSYM_NAMES = {
    0xFF08: "Backspace",
    0xFF09: "Tab",
    0xFF0D: "Enter",
    0xFF1B: "GoBack",
    0xFF50: "GoHome",
    0xFF51: "ArrowLeft",
    0xFF52: "ArrowUp",
    0xFF53: "ArrowRight",
    0xFF54: "ArrowDown",
    0xFF55: "PageUp",
    0xFF56: "PageDown",
    0xFF57: "End",
    0xFF63: "Insert",
    0xFFFF: "Delete",
    0xFFE1: "Shift",
    0xFFE2: "Shift",
    0xFFE3: "Control",
    0xFFE4: "Control",
    0xFFE7: "Meta",
    0xFFE8: "Meta",
    0xFFE9: "Alt",
    0xFFEA: "Alt",
}


def read_exact(stream: BinaryIO | socket.socket, length: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        chunk = stream.recv(length - len(chunks)) if isinstance(stream, socket.socket) else stream.read(length - len(chunks))
        if not chunk:
            raise EOFError("RFB peer disconnected")
        chunks.extend(chunk)
    return bytes(chunks)


def rgb_to_bgrx(rgb: bytes, width: int, height: int) -> bytes:
    expected = width * height * 3
    if len(rgb) != expected:
        raise ValueError(f"RGB frame has {len(rgb)} bytes; expected {expected}")
    result = bytearray(width * height * 4)
    target = memoryview(result)
    # AEMU 37.1.7's RGB888 stream is delivered top-down even though the
    # generic Image proto still describes the historical bottom-up layout.
    # Preserve row order so the displayed frame and touchscreen coordinates
    # share the same origin.
    target[0::4] = rgb[2::3]
    target[1::4] = rgb[1::3]
    target[2::4] = rgb[0::3]
    target[3::4] = b"\x00" * (width * height)
    return bytes(result)


def decode_json_stream(stream: BinaryIO):
    decoder = json.JSONDecoder()
    buffer = ""
    while True:
        chunk = stream.read(65536)
        if not chunk:
            return
        buffer += chunk.decode("utf-8") if isinstance(chunk, bytes) else chunk
        while True:
            buffer = buffer.lstrip()
            if not buffer:
                break
            try:
                value, consumed = decoder.raw_decode(buffer)
            except json.JSONDecodeError:
                break
            yield value
            buffer = buffer[consumed:]


class Grpcurl:
    def __init__(self, binary: str, proto_dir: str, endpoint: str):
        self.binary = binary
        self.proto_dir = proto_dir
        self.endpoint = endpoint

    def command(self, payload: str, method: str) -> list[str]:
        return [
            self.binary,
            "-plaintext",
            "-import-path",
            self.proto_dir,
            "-proto",
            "emulator_controller.proto",
            "-d",
            payload,
            self.endpoint,
            f"{CONTROLLER}/{method}",
        ]


class InputStream:
    def __init__(self, grpcurl: Grpcurl):
        self.process = subprocess.Popen(
            grpcurl.command("@", "streamInputEvent"),
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=sys.stderr,
            text=True,
            bufsize=1,
        )
        self.lock = threading.Lock()

    def send(self, event: dict) -> None:
        encoded = json.dumps(event, separators=(",", ":"))
        with self.lock:
            if self.process.poll() is not None or self.process.stdin is None:
                raise RuntimeError("AEMU input stream exited")
            self.process.stdin.write(encoded + "\n")
            self.process.stdin.flush()

    def close(self) -> None:
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()


@dataclass
class FrameStore:
    width: int
    height: int
    condition: threading.Condition = field(default_factory=threading.Condition)
    pixels: bytes | None = None
    sequence: int = -1

    def publish(self, pixels: bytes, sequence: int) -> None:
        with self.condition:
            self.pixels = pixels
            self.sequence = sequence
            self.condition.notify_all()


@dataclass
class ClientState:
    condition: threading.Condition = field(default_factory=threading.Condition)
    requested: bool = False
    incremental: bool = False
    last_sequence: int = -1
    stopped: bool = False


class RfbServer:
    def __init__(self, host: str, port: int, frames: FrameStore, inputs: InputStream):
        self.host = host
        self.port = port
        self.frames = frames
        self.inputs = inputs
        self.listener: socket.socket | None = None
        self.started = threading.Event()
        self.failure: BaseException | None = None

    def serve_forever(self) -> None:
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((self.host, self.port))
                listener.listen(8)
                self.listener = listener
                self.started.set()
                LOG.info("RFB listening on %s:%d", self.host, self.port)
                while True:
                    client, address = listener.accept()
                    thread = threading.Thread(target=self._serve_client, args=(client, address), daemon=True)
                    thread.start()
        except BaseException as error:
            self.failure = error
            self.started.set()

    def _handshake(self, client: socket.socket) -> None:
        client.sendall(b"RFB 003.008\n")
        version = read_exact(client, 12)
        if not version.startswith(b"RFB 003."):
            raise ValueError("unsupported RFB client version")
        client.sendall(b"\x01\x01")
        if read_exact(client, 1) != b"\x01":
            raise ValueError("RFB client rejected loopback security type None")
        client.sendall(struct.pack(">I", 0))
        read_exact(client, 1)
        name = b"cloudAndx Android"
        client.sendall(
            struct.pack(">HH", self.frames.width, self.frames.height)
            + SERVER_PIXEL_FORMAT
            + struct.pack(">I", len(name))
            + name
        )

    def _serve_client(self, client: socket.socket, address) -> None:
        state = ClientState()
        sender: threading.Thread | None = None
        try:
            self._handshake(client)
            LOG.info("RFB client connected from %s", address[0])
            sender = threading.Thread(target=self._send_frames, args=(client, state), daemon=True)
            sender.start()
            active_touch = False
            while True:
                message_type = read_exact(client, 1)[0]
                if message_type == 0:
                    read_exact(client, 19)
                elif message_type == 2:
                    header = read_exact(client, 3)
                    count = struct.unpack(">H", header[1:])[0]
                    read_exact(client, count * 4)
                elif message_type == 3:
                    request = read_exact(client, 9)
                    with state.condition:
                        state.incremental = bool(request[0])
                        state.requested = True
                        state.condition.notify_all()
                elif message_type == 4:
                    event = read_exact(client, 7)
                    down = bool(event[0])
                    keysym = struct.unpack(">I", event[3:])[0]
                    key = KEYSYM_NAMES.get(keysym)
                    if key is None and 32 <= keysym < 127:
                        key = chr(keysym)
                    if key:
                        self.inputs.send({"keyEvent": {"eventType": "keydown" if down else "keyup", "key": key}})
                elif message_type == 5:
                    event = read_exact(client, 5)
                    buttons, x, y = struct.unpack(">BHH", event)
                    pressed = bool(buttons & 1)
                    if pressed or active_touch:
                        pressure = 1024 if pressed else 0
                        self.inputs.send({"touchEvent": {"touches": [{"x": x, "y": y, "identifier": 0, "pressure": pressure, "expiration": "NEVER_EXPIRE"}]}})
                    active_touch = pressed
                elif message_type == 6:
                    header = read_exact(client, 7)
                    length = struct.unpack(">I", header[3:])[0]
                    text = read_exact(client, length).decode("utf-8", errors="replace")
                    if text:
                        self.inputs.send({"keyEvent": {"text": text}})
                else:
                    raise ValueError(f"unsupported RFB client message {message_type}")
        except (EOFError, ConnectionError, OSError, ValueError, RuntimeError) as error:
            LOG.info("RFB client disconnected: %s", error)
        finally:
            with state.condition:
                state.stopped = True
                state.condition.notify_all()
            if sender:
                sender.join(timeout=2)
            client.close()

    def _send_frames(self, client: socket.socket, state: ClientState) -> None:
        try:
            while True:
                with state.condition:
                    state.condition.wait_for(lambda: state.requested or state.stopped)
                    if state.stopped:
                        return
                    incremental = state.incremental
                with self.frames.condition:
                    self.frames.condition.wait_for(
                        lambda: self.frames.pixels is not None
                        and (not incremental or self.frames.sequence > state.last_sequence)
                    )
                    pixels = self.frames.pixels
                    sequence = self.frames.sequence
                assert pixels is not None
                rectangle = struct.pack(">BBH", 0, 0, 1) + struct.pack(">HHHHi", 0, 0, self.frames.width, self.frames.height, 0)
                client.sendall(rectangle + pixels)
                with state.condition:
                    state.last_sequence = sequence
                    state.requested = False
        except (ConnectionError, OSError):
            with state.condition:
                state.stopped = True
                state.condition.notify_all()


def stream_frames(grpcurl: Grpcurl, frames: FrameStore, ready_file: Path) -> None:
    request = json.dumps({"format": "RGB888", "width": frames.width, "height": frames.height})
    process = subprocess.Popen(
        grpcurl.command(request, "streamScreenshot"),
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
    )
    assert process.stdout is not None
    first = True
    for frame in decode_json_stream(process.stdout):
        rgb = base64.b64decode(frame.get("image", ""), validate=True)
        pixels = rgb_to_bgrx(rgb, frames.width, frames.height)
        frames.publish(pixels, int(frame.get("seq", frames.sequence + 1)))
        if first:
            ready_file.parent.mkdir(parents=True, exist_ok=True)
            ready_file.touch(mode=0o600, exist_ok=True)
            LOG.info("AEMU framebuffer first frame is ready")
            first = False
    status = process.wait()
    raise RuntimeError(f"AEMU screenshot stream exited with status {status}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--grpcurl", required=True)
    parser.add_argument("--proto-dir", required=True)
    parser.add_argument("--endpoint", default="127.0.0.1:8556")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=5900)
    parser.add_argument("--width", type=int, default=480)
    parser.add_argument("--height", type=int, default=1080)
    parser.add_argument("--ready-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="[aemu-rfb] %(message)s")
    ready_file = Path(args.ready_file)
    ready_file.unlink(missing_ok=True)
    grpcurl = Grpcurl(args.grpcurl, args.proto_dir, args.endpoint)
    inputs = InputStream(grpcurl)
    frames = FrameStore(args.width, args.height)
    server = RfbServer(args.listen_host, args.listen_port, frames, inputs)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    try:
        if not server.started.wait(timeout=10):
            raise RuntimeError("RFB listener did not start within 10 seconds")
        if server.failure:
            raise RuntimeError("RFB listener failed") from server.failure
        stream_frames(grpcurl, frames, ready_file)
    finally:
        ready_file.unlink(missing_ok=True)
        inputs.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
