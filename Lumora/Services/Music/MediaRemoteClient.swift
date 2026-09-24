import AppKit
import CoreFoundation
import Darwin
import Foundation

struct MediaRemoteSnapshot: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let timestamp: Date?
    let playbackRate: Double?
    let artworkData: Data?
    let isPlaying: Bool
    let bundleIdentifier: String?

    init(info: NSDictionary?, isPlaying: Bool, processIdentifier: Int32) {
        func value(_ key: String) -> Any? {
            info?.object(forKey: key)
        }

        func string(_ key: String) -> String? {
            guard let rawValue = value(key), !(rawValue is NSNull) else { return nil }
            return rawValue as? String
        }

        func number(_ key: String) -> Double? {
            guard let rawValue = value(key), !(rawValue is NSNull),
                  let number = rawValue as? NSNumber, number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }

        title = string("kMRMediaRemoteNowPlayingInfoTitle")
        artist = string("kMRMediaRemoteNowPlayingInfoArtist")
        album = string("kMRMediaRemoteNowPlayingInfoAlbum")
        duration = number("kMRMediaRemoteNowPlayingInfoDuration")
        elapsedTime = number("kMRMediaRemoteNowPlayingInfoElapsedTime")
        playbackRate = number("kMRMediaRemoteNowPlayingInfoPlaybackRate")

        if let date = value("kMRMediaRemoteNowPlayingInfoTimestamp") as? Date {
            timestamp = date
        } else if let seconds = number("kMRMediaRemoteNowPlayingInfoTimestamp"), seconds >= 1_000_000_000 {
            timestamp = Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        } else {
            timestamp = nil
        }

        if let data = value("kMRMediaRemoteNowPlayingInfoArtworkData") as? Data {
            artworkData = data.isEmpty ? nil : data
        } else {
            artworkData = nil
        }

        self.isPlaying = isPlaying
        bundleIdentifier = processIdentifier > 0
            ? NSRunningApplication(processIdentifier: pid_t(processIdentifier))?.bundleIdentifier
            : nil
    }
}

enum MediaRemoteClientError: Error {
    case frameworkUnavailable(String)
    case requestTimedOut
}

/// Small, app-owned dynamic binding to the system's MediaRemote service.
/// The private framework is resolved at runtime instead of linked into the target.
final class MediaRemoteClient {
    static let shared = MediaRemoteClient()

    private typealias InfoHandler = @convention(block) (CFDictionary?) -> Void
    private typealias GetInfoFunction = @convention(c) (DispatchQueue, @escaping InfoHandler) -> Void
    private typealias PlayingHandler = @convention(block) (Bool) -> Void
    private typealias GetPlayingFunction = @convention(c) (DispatchQueue, @escaping PlayingHandler) -> Void
    private typealias PIDHandler = @convention(block) (Int32) -> Void
    private typealias GetPIDFunction = @convention(c) (DispatchQueue, @escaping PIDHandler) -> Void
    private typealias SendCommandFunction = @convention(c) (UInt32, NSDictionary?) -> Void

    private let libraryHandle: UnsafeMutableRawPointer?
    private let loadError: String?
    private let getInfo: GetInfoFunction?
    private let getPlaying: GetPlayingFunction?
    private let getPID: GetPIDFunction?
    private let sendCommandFunction: SendCommandFunction?

    private init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            libraryHandle = nil
            loadError = dlerror().map { String(cString: $0) } ?? "Unable to load MediaRemote"
            getInfo = nil
            getPlaying = nil
            getPID = nil
            sendCommandFunction = nil
            return
        }

        libraryHandle = handle
        getInfo = Self.resolve("MRMediaRemoteGetNowPlayingInfo", in: handle, as: GetInfoFunction.self)
        getPlaying = Self.resolve("MRMediaRemoteGetNowPlayingApplicationIsPlaying", in: handle, as: GetPlayingFunction.self)
        getPID = Self.resolve("MRMediaRemoteGetNowPlayingApplicationPID", in: handle, as: GetPIDFunction.self)
        sendCommandFunction = Self.resolve("MRMediaRemoteSendCommand", in: handle, as: SendCommandFunction.self)

        if getInfo == nil || getPlaying == nil || getPID == nil || sendCommandFunction == nil {
            loadError = "One or more required MediaRemote functions are unavailable"
        } else {
            loadError = nil
        }
    }

    deinit {
        if let libraryHandle { dlclose(libraryHandle) }
    }

    func fetchNowPlayingInfo(
        completion: @escaping (Result<MediaRemoteSnapshot, MediaRemoteClientError>) -> Void
    ) {
        guard let getInfo, let getPlaying, let getPID else {
            completion(.failure(loadError.map { .frameworkUnavailable($0) } ?? .frameworkUnavailable("MediaRemote is unavailable")))
            return
        }

        var info: NSDictionary?
        var isPlaying = false
        var processIdentifier: Int32 = 0
        var receivedResponses = 0
        var didComplete = false
        let timeout = DispatchWorkItem {
            guard !didComplete else { return }
            didComplete = true
            completion(.failure(.requestTimedOut))
        }

        func recordResponse() {
            receivedResponses += 1
            guard receivedResponses == 3, !didComplete else { return }
            didComplete = true
            timeout.cancel()
            completion(.success(MediaRemoteSnapshot(
                info: info,
                isPlaying: isPlaying,
                processIdentifier: processIdentifier
            )))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        let queue = DispatchQueue.main
        getInfo(queue) { dictionary in
            info = dictionary as NSDictionary?
            recordResponse()
        }
        getPlaying(queue) { playing in
            isPlaying = playing
            recordResponse()
        }
        getPID(queue) { pid in
            processIdentifier = pid
            recordResponse()
        }
    }

    @discardableResult
    func send(command: UInt32) -> Bool {
        guard let sendCommandFunction else { return false }
        sendCommandFunction(command, nil)
        return true
    }

    private static func resolve<Function>(_ name: String, in handle: UnsafeMutableRawPointer, as type: Function.Type) -> Function? {
        guard let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }
}
