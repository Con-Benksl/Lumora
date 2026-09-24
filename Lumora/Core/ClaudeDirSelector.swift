//
//  ClaudeDirSelector.swift
//  Lumora
//
//  Manages the expand/collapse state of the Claude directory picker row.
//

import Combine
import Foundation

@MainActor
class ClaudeDirSelector: ObservableObject {
    static let shared = ClaudeDirSelector()

    @Published var isPickerExpanded: Bool = false

    private init() {}
}
