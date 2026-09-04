#if canImport(AudioPDF)
import XCTest
@testable import AudioPDF

@MainActor
final class PersistenceTests: XCTestCase {
    func testLibrarySettingsAndResumeRoundTrip() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let store = LibraryStore(databaseURL: database)
        let document = LibraryDocument(title: "Book", bookmark: Data([1, 2, 3]))
        document.resumePosition = 42.5
        document.playbackSpeed = 1.5
        document.selectedVoiceID = "voice"
        try store.add(document)

        let reloaded = LibraryStore(databaseURL: database)
        let restored = try XCTUnwrap(reloaded.documents.first)
        XCTAssertEqual(restored.resumePosition, 42.5)
        XCTAssertEqual(restored.playbackSpeed, 1.5)
        XCTAssertEqual(restored.selectedVoiceID, "voice")
        XCTAssertNil(restored.folderID)
    }

    func testNestedFoldersAndDocumentPlacementRoundTrip() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let store = LibraryStore(databaseURL: database)
        let parent = try store.addFolder(name: "Books", parentID: nil)
        let child = try store.addFolder(name: "Fiction", parentID: parent.id)
        try store.add(LibraryDocument(title: "Novel", bookmark: Data(), folderID: child.id))

        let reloaded = LibraryStore(databaseURL: database)
        XCTAssertEqual(reloaded.folderTree.first?.folder.name, "Books")
        XCTAssertEqual(reloaded.folderTree.first?.children.first?.folder.name, "Fiction")
        XCTAssertEqual(reloaded.documents.first?.folderID, child.id)
    }

    func testMovingAndDeletingNestedFolderUpdatesLibraryEntries() throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: database) }
        let store = LibraryStore(databaseURL: database)
        let parent = try store.addFolder(name: "Books", parentID: nil)
        let child = try store.addFolder(name: "Fiction", parentID: parent.id)
        let document = LibraryDocument(title: "Novel", bookmark: Data())
        try store.add(document)

        try store.move([document.id], to: child.id)
        XCTAssertEqual(store.documents.first?.folderID, child.id)

        let deleted = try store.deleteFolder(parent)
        XCTAssertEqual(deleted, [document.id])
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.folders.isEmpty)
    }
}
#endif
