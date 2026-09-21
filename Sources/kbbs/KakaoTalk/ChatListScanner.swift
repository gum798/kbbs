import ApplicationServices.HIServices
import Foundation

enum ChatTextNormalizer {
    static func normalize(_ text: String) -> String {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    static func isTimeLikeValue(_ value: String) -> Bool {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // KakaoTalk writes today's rooms as "오후 1:21". Without this the whole top of
        // the chat list — every room from today — came back with no timestamp at all,
        // while 어제 and N일 rows below it were filled in.
        for meridiem in ["오전", "오후", "AM", "PM"] where trimmed.hasPrefix(meridiem) {
            trimmed = String(trimmed.dropFirst(meridiem.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        let parts = trimmed.split(separator: ":")
        if parts.count == 2,
           parts[0].count <= 2, parts[1].count == 2,
           parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        {
            return true
        }

        if trimmed.hasSuffix("일") || trimmed == "어제" || trimmed == "그저께" {
            return true
        }

        return false
    }

    /// A timestamp in the five cells the 시각 column has.
    ///
    /// KakaoTalk writes "오후 1:21"; the column holds "21:03". Anything that is not a
    /// clock time — 어제, 3일 — is already short and is returned untouched.
    static func compactTime(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let afternoon = ["오후", "PM"].first { trimmed.hasPrefix($0) }
        let morning = ["오전", "AM"].first { trimmed.hasPrefix($0) }
        guard let meridiem = afternoon ?? morning else { return trimmed }

        let clock = String(trimmed.dropFirst(meridiem.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clock.split(separator: ":")
        guard parts.count == 2, var hour = Int(parts[0]), let minute = Int(parts[1]),
              (1...12).contains(hour), (0...59).contains(minute)
        else {
            return trimmed
        }

        // 12 is the hinge in both directions: 오전 12시 is 00, 오후 12시 stays 12.
        if afternoon != nil {
            hour = hour == 12 ? 12 : hour + 12
        } else {
            hour = hour == 12 ? 0 : hour
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// The unread badge as a number, or nil if this text is not a badge.
    ///
    /// KakaoTalk caps the badge at "999+", where the true count is unknowable, so the
    /// floor is the honest reading. A room with nothing unread has no badge at all,
    /// so a literal "0" is something else and is rejected.
    static func unreadCount(from value: String, identifier: String? = nil) -> Int? {
        guard identifier != "_NS:40", identifier != "_NS:69" else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUnreadCountLike(trimmed) else { return nil }
        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty, let count = Int(digits), count > 0 else { return nil }
        return count
    }

    static func isUnreadCountLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "+" || $0 == "," }
    }

    static func isTitleText(_ value: String, identifier: String?) -> Bool {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A real room named "16" uses _NS:40; its unread badge is a separate Count Label.
        if identifier == "_NS:40" { return true }
        if identifier == "Count Label" || identifier == "_NS:69" { return false }
        return !isTimeLikeValue(value) && !isUnreadCountLike(value)
    }
}

struct ChatListDiscovery {
    let title: String
    let lastMessage: String?
    let listIndex: Int

    /// Both are read from nodes the row scan already visits and the title/preview
    /// filters already reject — the badge node carries identifier "Count Label", and
    /// the timestamp is whatever ChatTextNormalizer.isTimeLikeValue accepts. Surfacing
    /// them costs no extra traversal. nil means the row did not expose one.
    var unreadCount: Int? = nil
    var timeLabel: String? = nil
}

struct ChatListEntry: Codable, Equatable {
    let title: String
    let chatID: String?
    let lastMessage: String?

    enum CodingKeys: String, CodingKey {
        case title
        case chatID = "chat_id"
        case lastMessage = "last_message"
    }
}

struct ChatListSnapshotItem {
    let element: UIElement
    let discovery: ChatListDiscovery
}

/// A row and the one thing opening it needs to know.
struct ChatRowHandle {
    let element: UIElement
    let title: String
}

struct ChatListScanner {
    func scan(in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> [ChatListSnapshotItem] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return []
        }

        let rows = collectChatItems(from: container, limit: limit)
        guard !rows.isEmpty else {
            trace?("chats: chat list container found but no rows/items resolved")
            return []
        }

        var snapshots: [ChatListSnapshotItem] = []
        snapshots.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            let title = extractTitle(from: row, trace: trace)
            let preview = extractPreview(from: row, title: title, trace: trace)
            // Walked once and handed to both. The badge and the timestamp were each
            // running this same uncached search over the row's subtree, which made the
            // two of them the most expensive thing in a sixty-row scan.
            let texts = row.findAll(role: kAXStaticTextRole, limit: 16, maxNodes: 100)
            let discovery = ChatListDiscovery(
                title: title,
                lastMessage: preview,
                listIndex: index,
                unreadCount: unreadCount(in: texts),
                timeLabel: timeLabel(in: texts)
            )
            snapshots.append(ChatListSnapshotItem(element: row, discovery: discovery))
        }

        trace?("chats: resolved rows=\(snapshots.count)")
        return snapshots
    }

    /// Rows and their titles, and nothing else.
    ///
    /// Opening a window asks the list one question: which row is this room. The preview,
    /// the badge and the timestamp each cost their own walk of the row's subtree and the
    /// open path throws all three away.
    func scanRows(in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> [ChatRowHandle] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else { return [] }
        return collectChatItems(from: container, limit: limit).map { row in
            ChatRowHandle(element: row, title: extractTitle(from: row, trace: trace))
        }
    }

    /// The row for one title, reading as little of the list as it can get away with.
    ///
    /// `rowCount` is reported even when the title is not among them, because the caller
    /// has to tell "the list has not redrawn yet" — where the count is one or zero —
    /// from "that room is genuinely not in the list".
    func findRow(titled title: String, in window: UIElement, limit: Int) -> (rowCount: Int, row: UIElement?) {
        guard let container = resolveChatListContainer(in: window) else { return (0, nil) }
        let rows = collectChatItems(from: container, limit: limit)
        for row in rows where extractTitle(from: row) == title {
            return (rows.count, row)
        }
        return (rows.count, nil)
    }

    func warmup(in window: UIElement, trace: ((String) -> Void)? = nil) -> [AXPathSlot] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            return []
        }

        var warmedSlots: [AXPathSlot] = [.chatListContainer]
        if let firstRow = collectChatItems(from: container, limit: 1).first {
            if extractTitleElement(from: firstRow, trace: trace)?.element != nil {
                warmedSlots.append(.chatRowTitle)
            }
            if extractPreviewElement(from: firstRow, title: extractTitle(from: firstRow, trace: trace), trace: trace)?.element != nil {
                warmedSlots.append(.chatRowPreview)
            }
        }

        return deduplicateSlots(warmedSlots)
    }

    private func resolveChatListContainer(in window: UIElement, trace: ((String) -> Void)? = nil) -> UIElement? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatListContainer,
            root: window,
            validate: isLikelyChatListContainer,
            trace: trace
        ) {
            trace?("chats: container fast path hit")
            return cached
        }

        trace?("chats: container fast path miss, scanning")
        let tables = window.findAll(role: kAXTableRole, limit: 1, maxNodes: 220)
        let outlines = window.findAll(role: kAXOutlineRole, limit: 1, maxNodes: 220)
        let lists = window.findAll(role: kAXListRole, limit: 1, maxNodes: 220)
        let container = tables.first ?? outlines.first ?? lists.first

        if let container {
            AXPathCacheStore.shared.remember(slot: .chatListContainer, root: window, element: container, trace: trace)
        }

        return container
    }

    private func isLikelyChatListContainer(_ element: UIElement) -> Bool {
        switch element.role {
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            return true
        default:
            return false
        }
    }

    private func collectChatItems(from container: UIElement, limit: Int) -> [UIElement] {
        let role = container.role ?? ""

        if role == kAXListRole {
            let children = Array(container.children.prefix(limit))
            return deduplicateElements(children)
        }

        let directRows = container.children.filter { $0.role == kAXRowRole }
        if !directRows.isEmpty {
            return Array(deduplicateElements(directRows).prefix(limit))
        }

        let discoveredRows = container.findAll(role: kAXRowRole, limit: limit, maxNodes: max(80, limit * 8))
        return deduplicateElements(discoveredRows)
    }

    private func extractTitle(from row: UIElement, trace: ((String) -> Void)? = nil) -> String {
        if let resolved = extractTitleElement(from: row, trace: trace) {
            return resolved.text
        }
        return "(Unknown Chat)"
    }

    private func extractTitleElement(from row: UIElement, trace: ((String) -> Void)? = nil) -> (element: UIElement, text: String)? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatRowTitle,
            root: row,
            validate: { candidate in
                titleText(from: candidate) != nil
            },
            trace: trace
        ), let text = titleText(from: cached) {
            return (cached, text)
        }

        if let text = titleText(from: row) {
            AXPathCacheStore.shared.remember(slot: .chatRowTitle, root: row, element: row, trace: trace)
            return (row, text)
        }

        let staticTexts = row.findAll(role: kAXStaticTextRole, limit: 12, maxNodes: 80)
        for textNode in staticTexts {
            guard let text = titleText(from: textNode) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowTitle, root: row, element: textNode, trace: trace)
            return (textNode, text)
        }

        return nil
    }

    /// The badge. KakaoTalk marks it with identifier "Count Label", which titleText and
    /// previewText both reject explicitly — so the node is already being looked at.
    private func unreadCount(in nodes: [UIElement]) -> Int? {
        for node in nodes where node.identifier == "Count Label" {
            let text = normalizedText(node.stringValue) ?? normalizedText(node.title)
            if let text, let count = ChatTextNormalizer.unreadCount(from: text) {
                return count
            }
        }
        // Some rows expose the badge without the identifier; fall back to shape.
        for node in nodes {
            let identifier = node.identifier
            guard identifier != "Count Label" else { continue }
            guard let text = normalizedText(node.stringValue) ?? normalizedText(node.title) else { continue }
            if let count = ChatTextNormalizer.unreadCount(from: text, identifier: identifier) {
                return count
            }
        }
        return nil
    }

    /// The row timestamp — "21:03", "어제", "3일". Filtered out of title and preview by
    /// isTimeLikeValue, which is exactly the predicate that identifies it here.
    private func timeLabel(in nodes: [UIElement]) -> String? {
        for node in nodes {
            guard let text = normalizedText(node.stringValue) ?? normalizedText(node.title) else { continue }
            if ChatTextNormalizer.isTimeLikeValue(text) {
                return ChatTextNormalizer.compactTime(text)
            }
        }
        return nil
    }

    private func extractPreview(from row: UIElement, title: String, trace: ((String) -> Void)? = nil) -> String? {
        extractPreviewElement(from: row, title: title, trace: trace)?.text
    }

    private func extractPreviewElement(from row: UIElement, title: String, trace: ((String) -> Void)? = nil) -> (element: UIElement, text: String)? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatRowPreview,
            root: row,
            validate: { candidate in
                previewText(from: candidate, title: title) != nil
            },
            trace: trace
        ), let text = previewText(from: cached, title: title) {
            return (cached, text)
        }

        let textAreas = row.findAll(role: kAXTextAreaRole, limit: 4, maxNodes: 60)
        for textArea in textAreas {
            guard let text = previewText(from: textArea, title: title) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowPreview, root: row, element: textArea, trace: trace)
            return (textArea, text)
        }

        let staticTexts = row.findAll(role: kAXStaticTextRole, limit: 16, maxNodes: 100)
        for textNode in staticTexts {
            guard let text = previewText(from: textNode, title: title) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowPreview, root: row, element: textNode, trace: trace)
            return (textNode, text)
        }

        return nil
    }

    private func titleText(from element: UIElement) -> String? {
        let identifier = element.identifier
        if let title = normalizedText(element.title), ChatTextNormalizer.isTitleText(title, identifier: identifier) {
            return title
        }

        if identifier == "Count Label" {
            return nil
        }

        switch element.role {
        case kAXRowRole, kAXCellRole, kAXGroupRole, kAXListRole, kAXTableRole, kAXOutlineRole:
            return nil
        default:
            break
        }

        if let value = normalizedText(element.stringValue), ChatTextNormalizer.isTitleText(value, identifier: identifier) {
            return value
        }

        return nil
    }

    private func previewText(from element: UIElement, title: String) -> String? {
        guard let value = normalizedText(element.stringValue) ?? normalizedText(element.title) else {
            return nil
        }
        if element.identifier == "Count Label" {
            return nil
        }
        if ChatTextNormalizer.isTimeLikeValue(value) || ChatTextNormalizer.isUnreadCountLike(value) {
            return nil
        }
        if ChatTextNormalizer.normalize(value) == ChatTextNormalizer.normalize(title) {
            return nil
        }
        return value
    }

    private func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        for element in elements {
            if unique.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateSlots(_ slots: [AXPathSlot]) -> [AXPathSlot] {
        var seen = Set<AXPathSlot>()
        return slots.filter { seen.insert($0).inserted }
    }
}
