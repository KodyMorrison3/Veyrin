/// Which character profile the popover shows, and the profiles Back returns to.
/// Entry points replace the current profile; similar characters push it onto the stack.
struct CharacterProfileNavigation: Equatable {
    private(set) var currentCharacterID: String?
    private(set) var backStack: [String] = []

    var canGoBack: Bool { !backStack.isEmpty }

    mutating func show(_ characterID: String) {
        currentCharacterID = characterID
    }

    mutating func openSimilar(_ characterID: String) {
        if let currentCharacterID {
            backStack.append(currentCharacterID)
        }
        currentCharacterID = characterID
    }

    mutating func back() {
        guard let previous = backStack.popLast() else { return }
        currentCharacterID = previous
    }

    mutating func dismiss() {
        self = CharacterProfileNavigation()
    }
}
