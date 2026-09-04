import Foundation
import Combine

final class LibraryDocument: ObservableObject, Identifiable {
    let id: UUID
    @Published var title: String
    var bookmark: Data
    var importedAt: Date
    var lastOpenedAt: Date
    @Published var resumePosition: Double
    @Published var audioDuration: Double
    var playbackSpeed: Double
    var selectedVoiceID: String
    var cacheKey: String?
    var folderID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        bookmark: Data,
        importedAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        resumePosition: Double = 0,
        audioDuration: Double = 0,
        playbackSpeed: Double = 1,
        selectedVoiceID: String = "",
        cacheKey: String? = nil,
        folderID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.bookmark = bookmark
        self.importedAt = importedAt
        self.lastOpenedAt = lastOpenedAt
        self.resumePosition = resumePosition
        self.audioDuration = audioDuration
        self.playbackSpeed = playbackSpeed
        self.selectedVoiceID = selectedVoiceID
        self.cacheKey = cacheKey
        self.folderID = folderID
    }
}

final class LibraryFolder: ObservableObject, Identifiable {
    let id: UUID
    @Published var name: String
    var parentID: UUID?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.createdAt = createdAt
    }
}

struct LibraryFolderNode: Identifiable {
    let folder: LibraryFolder
    let children: [LibraryFolderNode]

    var id: UUID { folder.id }
    var optionalChildren: [LibraryFolderNode]? { children.isEmpty ? nil : children }
}
