import SwiftUI

// Words and phrases chosen in Settings. A Reddit, RSS or YouTube post whose title
// contains one is left out of every feed. Saved posts stay shown.
struct BlockedWords {
    private(set) var words: [String]
    private let patterns: [NSRegularExpression]

    init(_ words: [String]) {
        self.words = words
        // Whole words only, ignoring case and accents: "cat" blocks "Cat" and "CAT!" but not "category".
        // Letters and digits count as word characters, so words such as "C++" match too.
        patterns = words.compactMap {
            try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])\(NSRegularExpression.escapedPattern(for: Self.fold($0)))(?![\\p{L}\\p{N}])")
        }
    }

    func blocks(_ title: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        let folded = Self.fold(title)
        let range = NSRange(folded.startIndex..., in: folded)
        return patterns.contains { $0.firstMatch(in: folded, range: range) != nil }
    }

    // The word as typed, trimmed, or nil when it is empty or already in the list.
    func normalized(_ word: String) -> String? {
        let trimmed = word.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty, !words.contains(where: { Self.fold($0) == Self.fold(trimmed) }) else { return nil }
        return trimmed
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func load() -> BlockedWords {
        BlockedWords(UserDefaults.standard.stringArray(forKey: Preference.blockedWords) ?? [])
    }

    func save() {
        UserDefaults.standard.set(words, forKey: Preference.blockedWords)
    }
}

struct BlockedWordsView: View {
    @EnvironmentObject private var store: FeedStore
    @State private var word = ""
    @FocusState private var wordFocused: Bool

    private var canAdd: Bool { store.blockedWords.normalized(word) != nil }

    private func add() {
        guard canAdd else { return }
        withAnimation { store.addBlockedWord(word) }
        word = ""
    }

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Word", text: $word, prompt: Text("Add a word or phrase"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($wordFocused)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canAdd)
                    .accessibilityLabel("Add")
                }
            } footer: {
                Text("Posts from Reddit, RSS and YouTube whose titles contain a blocked word are hidden. Matches whole words, ignoring case. Saved posts are still shown.")
            }
            if !store.blockedWords.words.isEmpty {
                Section("Blocked") {
                    ForEach(store.blockedWords.words, id: \.self) { Text($0) }
                        .onDelete { store.removeBlockedWords(at: $0) }
                }
            }
        }
        .navigationTitle("Blocked Words")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.blockedWords.words.isEmpty { EditButton() }
        }
    }
}
