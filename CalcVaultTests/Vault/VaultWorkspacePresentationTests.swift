import Foundation
import XCTest
@testable import CalcVault

final class VaultWorkspacePresentationTests: XCTestCase {
    func testDraftWithoutPendingEditorDoesNotPresent() {
        let item = makeItem(kind: .note)
        let draft = VaultNoteDraft(item: item, body: "body")

        guard case .none = vaultNoteDraftPresentationDecision(
            draft: draft,
            pendingNoteEditorItemID: nil
        ) else {
            return XCTFail("A draft must not open an editor without an active request")
        }
    }

    func testMatchingPendingNoteRoutesDirectlyToEditor() {
        let item = makeItem(kind: .note)
        let draft = VaultNoteDraft(item: item, body: "decrypted body")

        guard case .editNote(let routedItem, let body) = vaultNoteDraftPresentationDecision(
            draft: draft,
            pendingNoteEditorItemID: item.id
        ) else {
            return XCTFail("Expected a direct note-editor route")
        }

        XCTAssertEqual(routedItem.id, item.id)
        XCTAssertEqual(body, "decrypted body")
    }

    func testPendingEditDoesNotPresentUnrelatedPreview() {
        let item = makeItem(kind: .note)
        let unrelated = makeItem(kind: .note)
        let draft = VaultNoteDraft(item: unrelated, body: "body")

        guard case .none = vaultNoteDraftPresentationDecision(
            draft: draft,
            pendingNoteEditorItemID: item.id
        ) else {
            return XCTFail("An unrelated draft must not compete with the pending editor")
        }
    }

    private func makeItem(kind: VaultItemKind) -> VaultManifestItem {
        VaultManifestItem(
            id: UUID(),
            kind: kind,
            displayName: "Fixture",
            createdAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            revision: 1
        )
    }
}
