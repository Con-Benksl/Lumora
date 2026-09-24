//
//  SoundSelector.swift
//  Lumora
//
//  Manages sound selection state for the settings menu
//

import Combine
import Foundation

@MainActor
class SoundSelector: ObservableObject {
    static let shared = SoundSelector()

    // MARK: - Published State

    @Published var isPickerExpanded: Bool = false

    private init() {}
}