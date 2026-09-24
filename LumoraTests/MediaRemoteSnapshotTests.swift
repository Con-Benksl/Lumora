import XCTest
@testable import Lumora

final class MediaRemoteSnapshotTests: XCTestCase {
    func testMapsNowPlayingMetadataAndArtwork() {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let artwork = Data([0x01, 0x02, 0x03])
        let info: NSDictionary = [
            "kMRMediaRemoteNowPlayingInfoTitle": "Track",
            "kMRMediaRemoteNowPlayingInfoArtist": "Artist",
            "kMRMediaRemoteNowPlayingInfoAlbum": "Album",
            "kMRMediaRemoteNowPlayingInfoDuration": NSNumber(value: 240.5),
            "kMRMediaRemoteNowPlayingInfoElapsedTime": NSNumber(value: 42.25),
            "kMRMediaRemoteNowPlayingInfoTimestamp": timestamp,
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": NSNumber(value: 1.0),
            "kMRMediaRemoteNowPlayingInfoArtworkData": artwork
        ]

        let snapshot = MediaRemoteSnapshot(info: info, isPlaying: true, processIdentifier: 0)

        XCTAssertEqual(snapshot.title, "Track")
        XCTAssertEqual(snapshot.artist, "Artist")
        XCTAssertEqual(snapshot.album, "Album")
        XCTAssertEqual(snapshot.duration, 240.5)
        XCTAssertEqual(snapshot.elapsedTime, 42.25)
        XCTAssertEqual(snapshot.timestamp, timestamp)
        XCTAssertEqual(snapshot.playbackRate, 1.0)
        XCTAssertEqual(snapshot.artworkData, artwork)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertNil(snapshot.bundleIdentifier)
    }

    func testMissingOrInvalidMetadataDoesNotInventValues() {
        let info: NSDictionary = [
            "kMRMediaRemoteNowPlayingInfoTitle": NSNull(),
            "kMRMediaRemoteNowPlayingInfoDuration": "unknown",
            "kMRMediaRemoteNowPlayingInfoTimestamp": NSNumber(value: 12)
        ]

        let snapshot = MediaRemoteSnapshot(info: info, isPlaying: false, processIdentifier: 0)

        XCTAssertNil(snapshot.title)
        XCTAssertNil(snapshot.duration)
        XCTAssertNil(snapshot.timestamp)
        XCTAssertNil(snapshot.artworkData)
        XCTAssertFalse(snapshot.isPlaying)
    }
}
