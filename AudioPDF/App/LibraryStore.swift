import Combine
import Foundation
import SQLite3

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var folders: [LibraryFolder] = []

    nonisolated(unsafe) private var database: OpaquePointer?
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("AudioPDF", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            self.databaseURL = support.appendingPathComponent("Library.sqlite3")
        }

        do {
            try open()
            try createSchema()
            try reload()
            cleanupCachesForMissingPDFs()
        } catch {
            assertionFailure("Library database failed: \(error.localizedDescription)")
        }
    }

    deinit {
        sqlite3_close(database)
    }

    var folderTree: [LibraryFolderNode] {
        makeFolderNodes(parentID: nil)
    }

    func documents(in folderID: UUID?) -> [LibraryDocument] {
        documents.filter { $0.folderID == folderID }
    }

    func documents(includingDescendantsOf folderID: UUID) -> [LibraryDocument] {
        let folderIDs = descendantFolderIDs(of: folderID)
        return documents.filter { document in
            document.folderID.map(folderIDs.contains) ?? false
        }
    }

    func add(_ document: LibraryDocument) throws {
        try save(document)
        documents.removeAll { $0.id == document.id }
        documents.append(document)
        sortDocuments()
    }

    func save(_ document: LibraryDocument) throws {
        let sql = """
            INSERT INTO documents
            (id, title, bookmark, imported_at, last_opened_at, resume_position,
             audio_duration, playback_speed, selected_voice_id, cache_key, folder_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              title=excluded.title,
              bookmark=excluded.bookmark,
              imported_at=excluded.imported_at,
              last_opened_at=excluded.last_opened_at,
              resume_position=excluded.resume_position,
              audio_duration=excluded.audio_duration,
              playback_speed=excluded.playback_speed,
              selected_voice_id=excluded.selected_voice_id,
              cache_key=excluded.cache_key,
              folder_id=excluded.folder_id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(statement) }

        bind(document.id.uuidString, at: 1, in: statement)
        bind(document.title, at: 2, in: statement)
        _ = document.bookmark.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
        }
        sqlite3_bind_double(statement, 4, document.importedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 5, document.lastOpenedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 6, document.resumePosition)
        sqlite3_bind_double(statement, 7, document.audioDuration)
        sqlite3_bind_double(statement, 8, document.playbackSpeed)
        bind(document.selectedVoiceID, at: 9, in: statement)
        bindOptional(document.cacheKey, at: 10, in: statement)
        bindOptional(document.folderID?.uuidString, at: 11, in: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    func delete(_ document: LibraryDocument) throws {
        try execute("DELETE FROM documents WHERE id = ?", value: document.id.uuidString)
        documents.removeAll { $0.id == document.id }
        removeCache(for: document.cacheKey)
    }

    func move(_ documentIDs: Set<UUID>, to folderID: UUID?) throws {
        guard !documentIDs.isEmpty else { return }
        for id in documentIDs {
            try execute("UPDATE documents SET folder_id = ? WHERE id = ?", values: [folderID?.uuidString, id.uuidString])
        }
        for document in documents where documentIDs.contains(document.id) {
            document.folderID = folderID
        }
    }

    func addFolder(name: String, parentID: UUID?) throws -> LibraryFolder {
        let folder = LibraryFolder(name: name, parentID: parentID)
        try save(folder)
        folders.append(folder)
        sortFolders()
        return folder
    }

    func rename(_ folder: LibraryFolder, to name: String) throws {
        folder.name = name
        try save(folder)
        sortFolders()
    }

    func deleteFolder(_ folder: LibraryFolder) throws -> Set<UUID> {
        let folderIDs = descendantFolderIDs(of: folder.id)
        let documentsToDelete = documents.filter { document in
            document.folderID.map(folderIDs.contains) ?? false
        }
        let documentIDs = Set(documentsToDelete.map(\.id))

        guard sqlite3_exec(database, "BEGIN IMMEDIATE TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw databaseError()
        }
        do {
            for id in folderIDs {
                try execute("DELETE FROM documents WHERE folder_id = ?", value: id.uuidString)
            }
            for id in folderIDs {
                try execute("DELETE FROM folders WHERE id = ?", value: id.uuidString)
            }
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }

        folders.removeAll { folderIDs.contains($0.id) }
        documents.removeAll { documentIDs.contains($0.id) }
        for document in documentsToDelete {
            removeCache(for: document.cacheKey)
        }
        return documentIDs
    }

    func reload() throws {
        let documentSQL = """
            SELECT id, title, bookmark, imported_at, last_opened_at,
                   resume_position, audio_duration, playback_speed, selected_voice_id, cache_key, folder_id
            FROM documents ORDER BY last_opened_at DESC
            """
        var documentStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, documentSQL, -1, &documentStatement, nil) == SQLITE_OK else {
            throw databaseError()
        }
        defer { sqlite3_finalize(documentStatement) }

        var loadedDocuments: [LibraryDocument] = []
        while sqlite3_step(documentStatement) == SQLITE_ROW {
            guard let idText = text(column: 0, in: documentStatement),
                  let id = UUID(uuidString: idText),
                  let title = text(column: 1, in: documentStatement) else { continue }
            let byteCount = Int(sqlite3_column_bytes(documentStatement, 2))
            let bookmark = sqlite3_column_blob(documentStatement, 2).map { Data(bytes: $0, count: byteCount) } ?? Data()
            loadedDocuments.append(LibraryDocument(
                id: id,
                title: title,
                bookmark: bookmark,
                importedAt: Date(timeIntervalSince1970: sqlite3_column_double(documentStatement, 3)),
                lastOpenedAt: Date(timeIntervalSince1970: sqlite3_column_double(documentStatement, 4)),
                resumePosition: sqlite3_column_double(documentStatement, 5),
                audioDuration: sqlite3_column_double(documentStatement, 6),
                playbackSpeed: sqlite3_column_double(documentStatement, 7),
                selectedVoiceID: text(column: 8, in: documentStatement) ?? "",
                cacheKey: text(column: 9, in: documentStatement),
                folderID: text(column: 10, in: documentStatement).flatMap(UUID.init(uuidString:))
            ))
        }

        var folderStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT id, name, parent_id, created_at FROM folders ORDER BY name COLLATE NOCASE",
            -1,
            &folderStatement,
            nil
        ) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(folderStatement) }

        var loadedFolders: [LibraryFolder] = []
        while sqlite3_step(folderStatement) == SQLITE_ROW {
            guard let idText = text(column: 0, in: folderStatement),
                  let id = UUID(uuidString: idText),
                  let name = text(column: 1, in: folderStatement) else { continue }
            loadedFolders.append(LibraryFolder(
                id: id,
                name: name,
                parentID: text(column: 2, in: folderStatement).flatMap(UUID.init(uuidString:)),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(folderStatement, 3))
            ))
        }
        documents = loadedDocuments
        folders = loadedFolders
    }

    private func save(_ folder: LibraryFolder) throws {
        let sql = """
            INSERT INTO folders (id, name, parent_id, created_at) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, parent_id=excluded.parent_id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        bind(folder.id.uuidString, at: 1, in: statement)
        bind(folder.name, at: 2, in: statement)
        bindOptional(folder.parentID?.uuidString, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, folder.createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func createSchema() throws {
        let documentSQL = """
            CREATE TABLE IF NOT EXISTS documents (
              id TEXT PRIMARY KEY NOT NULL,
              title TEXT NOT NULL,
              bookmark BLOB NOT NULL,
              imported_at REAL NOT NULL,
              last_opened_at REAL NOT NULL,
              resume_position REAL NOT NULL,
              audio_duration REAL NOT NULL DEFAULT 0,
              playback_speed REAL NOT NULL,
              selected_voice_id TEXT NOT NULL,
              cache_key TEXT,
              folder_id TEXT
            )
            """
        guard sqlite3_exec(database, documentSQL, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        if !columnExists("audio_duration", in: "documents") {
            guard sqlite3_exec(database, "ALTER TABLE documents ADD COLUMN audio_duration REAL NOT NULL DEFAULT 0", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        }
        if !columnExists("folder_id", in: "documents") {
            guard sqlite3_exec(database, "ALTER TABLE documents ADD COLUMN folder_id TEXT", nil, nil, nil) == SQLITE_OK else { throw databaseError() }
        }
        let folderSQL = """
            CREATE TABLE IF NOT EXISTS folders (
              id TEXT PRIMARY KEY NOT NULL,
              name TEXT NOT NULL,
              parent_id TEXT,
              created_at REAL NOT NULL
            )
            """
        guard sqlite3_exec(database, folderSQL, nil, nil, nil) == SQLITE_OK else { throw databaseError() }
    }

    private func makeFolderNodes(parentID: UUID?) -> [LibraryFolderNode] {
        folders
            .filter { $0.parentID == parentID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { LibraryFolderNode(folder: $0, children: makeFolderNodes(parentID: $0.id)) }
    }

    private func descendantFolderIDs(of rootID: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [rootID]
        var pending = [rootID]
        while let parentID = pending.popLast() {
            let children = folders.filter { $0.parentID == parentID }.map(\.id)
            ids.formUnion(children)
            pending.append(contentsOf: children)
        }
        return ids
    }

    private func columnExists(_ name: String, in table: String) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(column: 1, in: statement) == name { return true }
        }
        return false
    }

    private func execute(_ sql: String, value: String) throws {
        try execute(sql, values: [value])
    }

    private func execute(_ sql: String, values: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            bindOptional(value, at: Int32(offset + 1), in: statement)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func bind(_ text: String, at index: Int32, in statement: OpaquePointer?) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }

    private func bindOptional(_ value: String?, at index: Int32, in statement: OpaquePointer?) {
        if let value { bind(value, at: index, in: statement) } else { sqlite3_bind_null(statement, index) }
    }

    private func text(column: Int32, in statement: OpaquePointer?) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private func sortDocuments() {
        documents.sort { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    private func sortFolders() {
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Removes the whole derived-cache directory for a document. This includes
    /// paragraph clips, the concatenated audiobook, and the manifest.
    func removeCache(for cacheKey: String?) {
        guard let cacheKey,
              cacheKey.count == 64,
              cacheKey.allSatisfy({ $0.isHexDigit }) else { return }
        guard !documents.contains(where: { $0.cacheKey == cacheKey }) else { return }
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("AudioPDF/AudioCache", isDirectory: true)
            .appendingPathComponent(cacheKey, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Removes caches only when the library still has a record for the PDF but
    /// its bookmarked source has been confirmed to be gone. Unreferenced cache
    /// directories are intentionally retained: a cache should not be treated
    /// as disposable merely because the database reference is temporarily
    /// unavailable or an older app version did not persist it yet.
    private func cleanupCachesForMissingPDFs() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioPDF/AudioCache", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        let missingKeys = Set(documents.compactMap { document -> String? in
            guard let cacheKey = document.cacheKey else { return nil }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: document.bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ),
                  url.startAccessingSecurityScopedResource() else {
                // An unresolved bookmark can mean that an external volume is
                // temporarily unavailable, so do not delete its cache.
                return nil
            }
            defer { url.stopAccessingSecurityScopedResource() }
            return FileManager.default.fileExists(atPath: url.path) ? nil : cacheKey
        })

        for entry in entries where missingKeys.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func open() throws {
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw databaseError() }
    }

    private func databaseError() -> NSError {
        let message = database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "Unknown SQLite error"
        return NSError(domain: "AudioPDF.SQLite", code: Int(sqlite3_errcode(database)), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
