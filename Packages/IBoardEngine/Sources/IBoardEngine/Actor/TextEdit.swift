/// A change to the text before the cursor: delete `deleteBackward` Characters (grapheme clusters, what one
/// `deleteBackward()` removes), then insert `insert`. Shared by the autocorrect and punctuation logic.
public struct TextEdit: Sendable, Equatable {
    public var deleteBackward: Int
    public var insert: String

    public init(deleteBackward: Int = 0, insert: String) {
        self.deleteBackward = deleteBackward
        self.insert = insert
    }
}
