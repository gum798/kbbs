import Foundation

struct MessageTranscriptContext {
    let inputElement: UIElement
    let chatPaneRoot: UIElement?
    let transcriptRoot: UIElement
}

struct MessageContextResolver {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let useCache: Bool
    private let interactionMode: ChatWindowInteractionMode

    init(
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        useCache: Bool = true,
        interactionMode: ChatWindowInteractionMode = .backgroundSafe
    ) {
        self.kakao = kakao
        self.runner = runner
        self.useCache = useCache
        self.interactionMode = interactionMode
    }

    func resolve(in chatWindow: UIElement) -> MessageTranscriptContext? {
        let r0 = Date()
        defer { runner.log("t: resolveContext \(Int(Date().timeIntervalSince(r0) * 1000))ms") }
        guard let inputElement = resolveMessageInputField(chatWindow: chatWindow) else {
            runner.log("read: message input context unavailable")
            return nil
        }

        let paneRoot = preferredChatPaneRoot(for: inputElement, in: chatWindow)
        if let paneRoot {
            runner.log("read: chat pane root role='\(paneRoot.role ?? "unknown")' frame=\(frameDescription(paneRoot.frame))")
        } else {
            runner.log("read: chat pane root unresolved; using window fallback")
        }

        guard let transcriptRoot = resolveTranscriptRoot(chatWindow: chatWindow, paneRoot: paneRoot, inputElement: inputElement) else {
            runner.log("read: transcript container unresolved")
            return nil
        }

        runner.log("read: transcript root role='\(transcriptRoot.role ?? "unknown")' frame=\(frameDescription(transcriptRoot.frame))")
        return MessageTranscriptContext(
            inputElement: inputElement,
            chatPaneRoot: paneRoot,
            transcriptRoot: transcriptRoot
        )
    }

    private func resolveMessageInputField(chatWindow: UIElement) -> UIElement? {
        let i0 = Date()
        defer { runner.log("t:   input \(Int(Date().timeIntervalSince(i0) * 1000))ms") }
        if let cachedInput = resolveCachedElement(
            slot: .messageInput,
            root: chatWindow,
            validate: { candidate in
                isLikelyMessageInputElement(candidate, in: chatWindow)
            }
        ) {
            return cachedInput
        }

        // Shallow first. The composer sits two levels down — window → scroll area → text
        // area — while the transcript's 120-odd rows sit one level further and soak up
        // any breadth-first node budget before it can get there. Walking the window's own
        // children by hand finds it in about a tenth of the time the general search takes.
        if let input = shallowComposer(in: chatWindow) {
            runner.log("read: input shallow hit role='\(input.role ?? "unknown")'")
            rememberCachedElement(slot: .messageInput, root: chatWindow, element: input)
            return input
        }

        if let focusedElement = kakao.applicationElement.focusedUIElement {
            let focusedCandidates = collectFocusedElementLineageCandidates(focusedElement)
            runner.log("read: input fast path focused candidates=\(focusedCandidates.count)")
            if let input = pickMessageInputField(from: focusedCandidates, in: chatWindow) {
                rememberCachedElement(slot: .messageInput, root: chatWindow, element: input)
                return input
            }
        }

        for attempt in 1...2 {
            var candidates: [UIElement] = []

            if let focusedWindow = kakao.focusedWindow {
                let focusedWindowCandidates = collectMessageInputCandidates(from: focusedWindow, limit: attempt == 1 ? 36 : 60)
                candidates.append(contentsOf: focusedWindowCandidates)
                if !areSameAXElement(focusedWindow, chatWindow) {
                    let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? 36 : 60)
                    candidates.append(contentsOf: chatWindowCandidates)
                }
                runner.log("read: input attempt \(attempt) focused=\(focusedWindowCandidates.count) total=\(candidates.count)")
            } else {
                let chatWindowCandidates = collectMessageInputCandidates(from: chatWindow, limit: attempt == 1 ? 36 : 60)
                candidates.append(contentsOf: chatWindowCandidates)
                runner.log("read: input attempt \(attempt) chatWindow=\(chatWindowCandidates.count)")
            }

            if let focusedElement = kakao.applicationElement.focusedUIElement {
                let focusedCandidates = collectFocusedElementLineageCandidates(focusedElement)
                candidates.append(contentsOf: focusedCandidates)
            }

            if attempt > 1 {
                candidates.append(contentsOf: collectMessageInputCandidates(from: kakao.applicationElement, limit: 60))
            }

            if let input = pickMessageInputField(from: deduplicateElements(candidates), in: chatWindow) {
                runner.log("read: input resolved attempt \(attempt) role='\(input.role ?? "unknown")'")
                rememberCachedElement(slot: .messageInput, root: chatWindow, element: input)
                return input
            }

            // No activation arm. A read that steals focus is indistinguishable from a
            // send, and kbbs polls every few seconds — the user would lose their
            // terminal continuously. If the input cannot be found quietly, it is not
            // found.
            runner.log("read: input not resolved on attempt \(attempt); not activating")
        }

        let appCandidates = collectMessageInputCandidates(from: kakao.applicationElement, limit: 90)
        runner.log("read: input final fallback app candidates=\(appCandidates.count)")
        if let input = pickMessageInputField(from: deduplicateElements(appCandidates), in: chatWindow) {
            rememberCachedElement(slot: .messageInput, root: chatWindow, element: input)
            return input
        }

        return nil
    }

    private func resolveTranscriptRoot(chatWindow: UIElement, paneRoot: UIElement?, inputElement: UIElement) -> UIElement? {
        let t0 = Date()
        defer { runner.log("t:   transcriptRoot \(Int(Date().timeIntervalSince(t0) * 1000))ms") }
        let cacheRoot = paneRoot ?? chatWindow
        if let cachedTranscriptRoot = resolveCachedElement(
            slot: .transcriptRoot,
            root: cacheRoot,
            validate: { candidate in
                isLikelyTranscriptRoot(candidate, chatWindow: chatWindow, inputElement: inputElement)
            }
        ) {
            runner.log("read: transcript root cache hit")
            return cachedTranscriptRoot
        }

        // Shallow first, for the same reason the input search does it: KakaoTalk answers
        // each Accessibility query in several milliseconds, so a 600-node breadth-first
        // walk is four to seven SECONDS. The transcript container is a direct child of
        // the window, and looking only there costs a few dozen queries.
        if let quick = shallowTranscriptRoot(chatWindow: chatWindow, inputElement: inputElement) {
            runner.log("read: transcript root shallow hit")
            rememberCachedElement(slot: .transcriptRoot, root: cacheRoot, element: quick)
            return quick
        }

        var candidates: [UIElement] = []

        if let paneRoot {
            candidates.append(contentsOf: collectTranscriptContainers(from: paneRoot))
        }

        candidates.append(contentsOf: collectTranscriptContainers(from: chatWindow))

        candidates = deduplicateElements(candidates)
        if candidates.isEmpty {
            return nil
        }

        // Phase 1: spatial/role scoring only (no BFS)
        var phase1 = candidates.map { candidate in
            (
                candidate: candidate,
                score: scoreTranscriptContainerSpatial(
                    candidate,
                    chatWindow: chatWindow,
                    inputElement: inputElement
                )
            )
        }
        .sorted { lhs, rhs in lhs.score > rhs.score }

        // Phase 2: child bonus via BFS for top 3 candidates only
        let topCount = min(3, phase1.count)
        for i in 0..<topCount {
            guard phase1[i].score > 0 else { continue }
            phase1[i].score += scoreTranscriptContainerChildBonus(phase1[i].candidate)
        }
        let scored = phase1.sorted { lhs, rhs in lhs.score > rhs.score }

        if let top = scored.first {
            runner.log("read: transcript candidates=\(scored.count) bestScore=\(Int(top.score))")
        }

        guard let transcriptRoot = scored.first(where: { $0.score > 0 })?.candidate else {
            return nil
        }

        rememberCachedElement(slot: .transcriptRoot, root: cacheRoot, element: transcriptRoot)
        return transcriptRoot
    }

    /// The transcript container, looked for only where it lives: the window's children
    /// and theirs.
    private func shallowTranscriptRoot(chatWindow: UIElement, inputElement: UIElement) -> UIElement? {
        let roles: Set<String> = [kAXScrollAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole]
        var candidates: [UIElement] = []
        for child in chatWindow.children.prefix(40) {
            if let role = child.role, roles.contains(role) {
                candidates.append(child)
            }
            guard child.role == kAXGroupRole || child.role == kAXScrollAreaRole else { continue }
            for grandchild in child.children.prefix(12) {
                if let role = grandchild.role, roles.contains(role) {
                    candidates.append(grandchild)
                }
            }
        }

        let best = candidates
            .map { ($0, scoreTranscriptContainerSpatial($0, chatWindow: chatWindow, inputElement: inputElement)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }
        guard let best, isLikelyTranscriptRoot(best.0, chatWindow: chatWindow, inputElement: inputElement) else {
            return nil
        }
        return best.0
    }

    private func collectTranscriptContainers(from root: UIElement) -> [UIElement] {
        let roles: Set<String> = [
            kAXScrollAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole, kAXGroupRole,
        ]
        let roleLimits: [String: Int] = [
            kAXScrollAreaRole: 12,
            kAXTableRole: 8,
            kAXOutlineRole: 8,
            kAXListRole: 8,
            kAXGroupRole: 10,
        ]
        let found = root.findAll(roles: roles, roleLimits: roleLimits, maxNodes: 600)

        var containers: [UIElement] = []
        for role in [kAXScrollAreaRole, kAXTableRole, kAXOutlineRole, kAXListRole, kAXGroupRole] {
            containers.append(contentsOf: found[role] ?? [])
        }
        return containers
    }

    /// Phase 1: spatial/role-based scoring (no BFS calls)
    private func scoreTranscriptContainerSpatial(_ candidate: UIElement, chatWindow: UIElement, inputElement: UIElement) -> Double {
        guard
            let windowFrame = chatWindow.frame,
            let inputFrame = inputElement.frame,
            let candidateFrame = candidate.frame
        else {
            return -Double.greatestFiniteMagnitude
        }

        let candidateWidthRatio = candidateFrame.width / max(windowFrame.width, 1)
        if candidateWidthRatio < 0.35 {
            return -8_000
        }

        let overlapWidth = max(0, min(candidateFrame.maxX, inputFrame.maxX) - max(candidateFrame.minX, inputFrame.minX))
        let overlapRatio = overlapWidth / max(min(candidateFrame.width, inputFrame.width), 1)
        if overlapRatio < 0.15 {
            return -7_000
        }

        var score: Double = 0
        let role = candidate.role ?? ""
        switch role {
        case kAXScrollAreaRole:
            score += 4_400
        case kAXTableRole:
            score += 3_600
        case kAXListRole, kAXOutlineRole:
            score += 3_000
        case kAXGroupRole:
            score += 1_500
        default:
            break
        }

        if candidateFrame.maxY <= inputFrame.minY + 24 {
            score += 1_300
        } else {
            score -= 2_800
        }

        score += overlapRatio * 2_200

        let centerX = (candidateFrame.midX - windowFrame.minX) / max(windowFrame.width, 1)
        if centerX < 0.35 {
            score -= 1_600
        }

        if candidateFrame.minY >= inputFrame.minY {
            score -= 3_000
        }

        if candidateFrame.height > inputFrame.height * 2.2 {
            score += 320
        }

        return score
    }

    /// Phase 2: child bonus via single multi-role BFS
    private func scoreTranscriptContainerChildBonus(_ candidate: UIElement) -> Double {
        let roles: Set<String> = [kAXRowRole, kAXStaticTextRole]
        let found = candidate.findAll(
            roles: roles,
            roleLimits: [kAXRowRole: 20, kAXStaticTextRole: 20],
            maxNodes: 240
        )
        let rowCount = found[kAXRowRole]?.count ?? 0
        let textCount = found[kAXStaticTextRole]?.count ?? 0
        return Double(rowCount * 150) + Double(textCount * 25)
    }

    private func isLikelyTranscriptRoot(_ candidate: UIElement, chatWindow: UIElement, inputElement: UIElement) -> Bool {
        let role = candidate.role ?? ""
        guard role == kAXScrollAreaRole || role == kAXTableRole || role == kAXOutlineRole || role == kAXListRole || role == kAXGroupRole else {
            return false
        }

        return scoreTranscriptContainerSpatial(candidate, chatWindow: chatWindow, inputElement: inputElement) > 0
    }

    private func preferredChatPaneRoot(for inputElement: UIElement, in chatWindow: UIElement) -> UIElement? {
        guard let windowFrame = chatWindow.frame else { return nil }
        let ancestors = ancestorChain(of: inputElement, maxHops: 8)

        let filtered = ancestors.filter { candidate in
            guard let frame = candidate.frame else { return false }
            guard isElementLikelyInsideWindow(elementFrame: frame, windowFrame: windowFrame) else { return false }
            let widthRatio = frame.width / max(windowFrame.width, 1)
            let heightRatio = frame.height / max(windowFrame.height, 1)
            return widthRatio >= 0.45 && heightRatio >= 0.35
        }

        return filtered.min { lhs, rhs in
            guard let lhsFrame = lhs.frame, let rhsFrame = rhs.frame else { return false }
            return lhsFrame.width * lhsFrame.height < rhsFrame.width * rhsFrame.height
        }
    }

    private func ancestorChain(of element: UIElement, maxHops: Int) -> [UIElement] {
        var ancestors: [UIElement] = []
        var cursor: UIElement? = element.parent
        var hops = 0

        while let current = cursor, hops < maxHops {
            ancestors.append(current)
            cursor = current.parent
            hops += 1
        }

        return ancestors
    }

    private func collectMessageInputCandidates(from root: UIElement, limit: Int = 80) -> [UIElement] {
        let nodeBudget = max(200, limit * 4)
        // Not `isEnabled`: KakaoTalk omits AXEnabled on its own composer, so asking for
        // enabled elements excluded the one element this whole function exists to find.
        let roleCandidates = root.findAll(where: { element in
            guard !element.isExplicitlyDisabled else { return false }
            return element.role == kAXTextAreaRole || element.role == kAXTextFieldRole
        }, limit: limit, maxNodes: nodeBudget)

        let editableCandidates = root.findAll(where: { element in
            guard !element.isExplicitlyDisabled else { return false }
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            guard editable else { return false }
            let role = element.role ?? ""
            return role != kAXStaticTextRole && role != kAXImageRole
        }, limit: limit, maxNodes: nodeBudget)

        return roleCandidates + editableCandidates
    }

    private func collectFocusedElementLineageCandidates(_ focusedElement: UIElement) -> [UIElement] {
        var candidates: [UIElement] = [focusedElement]
        var cursor: UIElement? = focusedElement.parent
        var hops = 0

        while let element = cursor, hops < 4 {
            candidates.append(element)
            let textDescendants = element.findAll(where: { node in
                guard node.isEnabled else { return false }
                return node.role == kAXTextAreaRole || node.role == kAXTextFieldRole
            }, limit: 8, maxNodes: 48)
            candidates.append(contentsOf: textDescendants)
            cursor = element.parent
            hops += 1
        }

        return candidates
    }

    /// The composer, found by looking only where it actually lives.
    ///
    /// The window's direct children and the direct children of each of those. That is
    /// two levels and a few dozen reads, and it deliberately never descends into the
    /// transcript, whose rows are themselves text areas and would both slow the search
    /// down and compete for the answer.
    private func shallowComposer(in chatWindow: UIElement) -> UIElement? {
        var candidates: [UIElement] = []
        for child in chatWindow.children.prefix(40) {
            if isLikelyMessageInputElement(child, in: chatWindow) {
                candidates.append(child)
            }
            guard child.role == kAXScrollAreaRole || child.role == kAXGroupRole else { continue }
            for grandchild in child.children.prefix(12) where isLikelyMessageInputElement(grandchild, in: chatWindow) {
                candidates.append(grandchild)
            }
        }
        return pickMessageInputField(from: candidates, in: chatWindow)
    }

    /// The best candidate that is actually a plausible message input, or nil.
    ///
    /// It used to rank the candidates and take the first, with no test that the winner
    /// could be an input at all. Whatever KakaoTalk happened to have focused came along
    /// in the candidate lineage, so on a window where the transcript had focus this
    /// returned the transcript's AXTable — and then injection wrote into a table, reads
    /// filtered rows against a table's frame, and nothing said anything was wrong.
    private func pickMessageInputField(from fields: [UIElement], in window: UIElement) -> UIElement? {
        fields
            .filter { isLikelyMessageInputElement($0, in: window) }
            .sorted { lhs, rhs in
                scoreMessageInputCandidate(lhs, in: window) > scoreMessageInputCandidate(rhs, in: window)
            }
            .first
    }

    private func scoreMessageInputCandidate(_ element: UIElement, in window: UIElement) -> Double {
        if !isLikelyMessageInputElement(element, in: window) {
            return -Double.greatestFiniteMagnitude
        }

        let role = element.role ?? ""
        let roleScore: Double
        if role == kAXTextAreaRole {
            roleScore = 12_000.0
        } else if role == kAXTextFieldRole {
            roleScore = 9_000.0
        } else {
            let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
            roleScore = editable ? 6_000.0 : 0.0
        }

        let yScore = Double(element.position?.y ?? 0)
        let topPenalty: Double
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            topPenalty = 8_000.0
        } else {
            topPenalty = 0.0
        }

        let locationScore: Double
        if let windowFrame = window.frame, let elementFrame = element.frame {
            if isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
                let relativeY = (elementFrame.midY - windowFrame.minY) / max(windowFrame.height, 1.0)
                locationScore = relativeY > 0.55 ? 1_500.0 : 0.0
            } else {
                locationScore = -6_000.0
            }
        } else {
            locationScore = 0.0
        }

        let sizeScore = Double(element.size?.height ?? 0)
        let focusScore = element.isFocused ? 2_000.0 : 0.0
        return roleScore + yScore + sizeScore + focusScore + locationScore - topPenalty
    }

    private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard !element.isExplicitlyDisabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole && isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    private func resolveCachedElement(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool
    ) -> UIElement? {
        guard useCache else { return nil }
        return AXPathCacheStore.shared.resolve(
            slot: slot,
            root: root,
            validate: validate,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {
        guard useCache else { return }
        AXPathCacheStore.shared.remember(
            slot: slot,
            root: root,
            element: element,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func deduplicateElements(_ candidates: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(candidates.count)
        for candidate in candidates {
            if unique.contains(where: { areSameAXElement($0, candidate) }) {
                continue
            }
            unique.append(candidate)
        }
        return unique
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }

    private func frameDescription(_ frame: CGRect?) -> String {
        guard let frame else { return "unknown" }
        return "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.size.width)) h=\(Int(frame.size.height))"
    }
}
