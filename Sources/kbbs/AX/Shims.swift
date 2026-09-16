import Foundation

/// Replacements for two things kbbs deleted but the retained scraper still names.
///
/// Both exist so that ChatListScanner, MessageContextResolver and TranscriptReader
/// compile untouched. Editing those three files to remove the references would be
/// more lines changed, in code we did not write, than declaring the names here.

// MARK: - AX path cache, disabled

/// kmsg persists resolved AX element paths to `~/.kmsg/ax-cache.json` to skip tree
/// walks on repeat runs. kbbs deletes that store (421 lines) rather than inheriting it:
///
///  - `AXPathCacheStore` was `@unchecked Sendable` over unsynchronised mutable state
///    (`cachedDocument`) and did unsynchronised whole-file writes. kbbs is a long-lived
///    process that would hold a stale in-memory document for hours.
///  - The cache only pays off across short-lived CLI invocations. kbbs resolves a
///    window once at boot and a transcript context once per room, then keeps the live
///    handles for the session, so there is nothing for it to save.
///
/// `resolve` always misses and `remember` always discards, which drives every call site
/// down its existing cold path. No behaviour is lost, only the file.
enum AXPathSlot: String, CaseIterable, Hashable {
    case searchField
    case messageInput
    case transcriptRoot
    case chatListContainer
    case chatRowTitle
    case chatRowPreview
}

final class AXPathCacheStore: @unchecked Sendable {
    static let shared = AXPathCacheStore()

    private init() {}

    func resolve(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool,
        trace: ((String) -> Void)? = nil
    ) -> UIElement? {
        trace?("cache: disabled, miss slot=\(slot.rawValue)")
        return nil
    }

    func remember(
        slot: AXPathSlot,
        root: UIElement,
        element: UIElement,
        trace: ((String) -> Void)? = nil
    ) {
        trace?("cache: disabled, discard slot=\(slot.rawValue)")
    }
}

// MARK: - Interaction mode

/// Declared in kmsg at ChatWindowResolver.swift:26 but referenced from
/// MessageContextResolver.swift:13/:19 and TranscriptReader.swift:103/:108, so deleting
/// the resolver without re-declaring it does not build.
///
/// kbbs only ever uses `.backgroundSafe`. The case that steals focus is kept solely so
/// the retained files' `switch` statements stay exhaustive.
enum ChatWindowInteractionMode {
    case allowUIAutomation
    case backgroundSafe
}
