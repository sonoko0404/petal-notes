#!/usr/bin/env python3
"""Compile attacks against the actual diagnostics API. Never logs user data."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1] / "PetalChecklist/App/Diagnostics.swift")
args = parser.parse_args()
probes = [
    (True, 'try await log.record(.current(subsystem: .storage, errorCode: .openFailed, syncState: .failed))'),
    (False, 'try await log.record("SYNTHETIC_PRIVATE_TITLE")'),
    (False, 'try await log.record(message: "SYNTHETIC_PRIVATE_TITLE")'),
    (False, 'try await log.record(metadata: ["userID": "SYNTHETIC_ID"])'),
    (False, 'try await log.record(error: NSError(domain: "SYNTHETIC_PRIVATE_PATH", code: 1))'),
    (False, 'let _ = DiagnosticEvent(timestamp: .now, subsystem: .storage, errorCode: .openFailed, syncState: .failed, appVersion: "SYNTHETIC_TITLE", osVersion: "SYNTHETIC_TEXT")')]
with tempfile.TemporaryDirectory(prefix="petal-diagnostics-api-") as tmp:
    probe = Path(tmp) / "Probe.swift"
    for allowed, body in probes:
        probe.write_text('import Foundation\nfunc probe(log: Diagnostics) async throws { ' + body + ' }\n')
        result = subprocess.run(["xcrun", "swiftc", "-typecheck", "-swift-version", "6", "-strict-concurrency=complete",
            "-target", platform.machine() + "-apple-macos14.0", str(args.source), str(probe)], capture_output=True, text=True)
        if (result.returncode == 0) != allowed:
            print("FAIL: content accepted by diagnostics API" if not allowed else "FAIL: typed diagnostic API does not compile")
            print(result.stderr)
            raise SystemExit(1)
print("PASS: typed event compiles; five content-bearing API attacks fail compilation")
