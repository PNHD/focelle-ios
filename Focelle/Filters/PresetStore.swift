import Combine
import Foundation

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var records: [UserPreset]
    @Published private(set) var syncError: String?

    var presets: [UserPreset] {
        records
            .filter { !$0.isDeleted }
            .sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.updatedAt > $1.updatedAt
            }
    }

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL
        records = (try? Self.load(from: self.fileURL)) ?? []
    }

    @discardableResult
    func create(
        name: String,
        recipe: FilterRecipe,
        intensity: Double,
        now: Date = .now
    ) -> UserPreset {
        let id = UUID()
        var customRecipe = recipe
        customRecipe.id = "user-\(id.uuidString)"
        let preset = UserPreset(
            id: id,
            name: UserPreset.sanitizedName(name),
            recipe: customRecipe.clamped(),
            intensity: min(max(intensity, 0), 1),
            updatedAt: now
        )
        records.append(preset)
        persist()
        return preset
    }

    func rename(_ id: UUID, to name: String, now: Date = .now) {
        update(id, now: now) {
            $0.name = UserPreset.sanitizedName(name)
        }
    }

    func setFavorite(_ id: UUID, _ value: Bool, now: Date = .now) {
        update(id, now: now) { $0.isFavorite = value }
    }

    func edit(
        _ id: UUID,
        recipe: FilterRecipe,
        intensity: Double,
        now: Date = .now
    ) {
        update(id, now: now) {
            $0.recipe = recipe.clamped()
            $0.intensity = min(max(intensity, 0), 1)
        }
    }

    func delete(_ id: UUID, now: Date = .now) {
        update(id, now: now) { $0.isDeleted = true }
    }

    func sync() async {
        do {
            records = UserPreset.merged(records, try await PresetSync.fetch())
            persist()
            try await PresetSync.push(records)
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func update(
        _ id: UUID,
        now: Date,
        change: (inout UserPreset) -> Void
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        records[index].updatedAt = now
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            syncError = error.localizedDescription
        }
    }

    private static func load(from url: URL) throws -> [UserPreset] {
        try JSONDecoder().decode([UserPreset].self, from: Data(contentsOf: url))
    }

    private static var defaultURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Focelle", directoryHint: .isDirectory)
            .appending(path: "presets.json")
    }
}
