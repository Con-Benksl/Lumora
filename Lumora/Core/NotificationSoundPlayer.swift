//
//  NotificationSoundPlayer.swift
//  Lumora
//
//  Plays notification sounds provided by macOS.
//

import AppKit
import Foundation

@MainActor
enum NotificationSoundPlayer {
    private static var activeSounds: [NSSound] = []

    static func play(_ notificationSound: NotificationSound) {
        guard let soundName = notificationSound.soundName else { return }
        guard let sound = NSSound(named: soundName) else { return }

        sound.volume = 1.0
        activeSounds.append(sound)
        sound.play()

        let retentionDuration = (sound.duration.isFinite && sound.duration > 0)
            ? sound.duration + 0.2
            : 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + retentionDuration) {
            activeSounds.removeAll { $0 === sound }
        }
    }

}
