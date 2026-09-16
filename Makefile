# kbbs convenience targets.
#
# Develop against ~/bin/kbbs, NOT .build/debug/kbbs. macOS keys Accessibility trust
# per binary, and `swift build` rewrites the binary on every change — so a moving path
# with a changing signature means re-granting permission in System Settings on every
# rebuild. A stable path plus a stable ad-hoc identity keeps the grant alive.

BIN := $(HOME)/bin/kbbs
BUMP := scripts/headatever.sh

.PHONY: build test install lint-print version release release-major release-push

build: ## Debug build
	@swift build

test: ## Unit tests — no KakaoTalk, no Accessibility grant needed
	@swift test

install: ## Release build to ~/bin/kbbs with a stable ad-hoc signature
	@swift build -c release
	@mkdir -p $(HOME)/bin
	@install -m 0755 .build/release/kbbs $(BIN)
	@codesign -s - --identifier dev.kbbs --force $(BIN)
	@echo "installed $(BIN)"

lint-print: ## Fail if a deleted hazard is reintroduced
	@! grep -rn --include='*.swift' \
		-e 'keyboardSetUnicodeString' \
		-e 'pressCommandW' \
		-e 'forceTypeIntoChatWindow' \
		-e 'NSWorkspace.shared.frontmostApplication' \
		-e 'func launch(' \
		-e 'forceOpen' \
		-e 'ensureMainWindow' \
		-e 'ensureWindowReopened' \
		-e 'activateAndWaitForWindow' \
		-e 'printHierarchy' \
		Sources/ \
		|| (echo "^^ a hazard deleted on purpose has come back"; exit 1)
	@! grep -nE 'UIElement|AXUIElement|KakaoTalkApp|ChatListScanner|RoomReader' \
		Sources/kbbs/App/Loop.swift Sources/kbbs/UI/*.swift \
		|| (echo "^^ the main thread must not touch Accessibility — send it to AXWorker"; exit 1)
	@echo "lint-print: clean"

version: ## Print the current version
	@$(BUMP) show

release: ## Patch release: bump VERSION, commit, tag v<version>
	@$(BUMP) patch

release-major: ## Head release: head+1, date=today, patch=0
	@$(BUMP) major

release-push: ## Patch release, then push commit + tag
	@$(BUMP) patch --push
