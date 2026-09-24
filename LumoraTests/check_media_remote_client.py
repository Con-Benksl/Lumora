#!/usr/bin/env python3
"""Read-only smoke test for Lumora's runtime MediaRemote bindings."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
sdk = Path(subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
source = repo / "Lumora/Services/Music/MediaRemoteClient.swift"
harness = r'''
import Foundation

@main struct Check {
    static func main() async {
        let result: Result<MediaRemoteSnapshot, MediaRemoteClientError> = await withCheckedContinuation { continuation in
            MediaRemoteClient.shared.fetchNowPlayingInfo { result in
                continuation.resume(returning: result)
            }
        }
        switch result {
        case .success(let snapshot):
            let hasMetadata = snapshot.title != nil || snapshot.artist != nil
            print("PASS: MediaRemote runtime bindings returned a snapshot (metadata present: \(hasMetadata))")
        case .failure(let error):
            fputs("FAIL: MediaRemote runtime request failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="lumora-media-remote-check-") as directory:
    directory = Path(directory)
    main = directory / "check.swift"
    main.write_text(harness)
    binary = directory / "check"
    subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library", "-sdk", str(sdk),
        str(source), str(main), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
