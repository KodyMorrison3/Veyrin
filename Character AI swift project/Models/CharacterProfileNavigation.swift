/// Which character profile the popover shows, and the profiles Back returns to.
/// Entry points replace the current profile; similar characters push it onto the stack.
struct CharacterProfileNavigation: Equatable {
    private(set) var currentCharacterID: String?
    private(set) var backStack: [String] = []

    var canGoBack: Bool { !backStack.isEmpty }

    mutating func show(_ characterID: String) {
        ProfileNavigationTrace.beginOperation("show", characterID: characterID, stack: backStack)
        currentCharacterID = characterID
    }

    mutating func openSimilar(_ characterID: String) {
        ProfileNavigationTrace.beginOperation("openSimilar", characterID: characterID, stack: backStack)
        if let currentCharacterID {
            backStack.append(currentCharacterID)
        }
        currentCharacterID = characterID
    }

    mutating func back() {
        guard let previous = backStack.popLast() else { return }
        ProfileNavigationTrace.beginOperation("back", characterID: previous, stack: backStack)
        currentCharacterID = previous
    }

    mutating func dismiss() {
        ProfileNavigationTrace.beginOperation("dismiss", characterID: currentCharacterID, stack: backStack)
        self = CharacterProfileNavigation()
    }
}
