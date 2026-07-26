import Foundation

struct UserPreset: Codable, Equatable, Identifiable, Sendable {
    var schemaVersion = 1
    let id: UUID
    var name: String
    var recipe: FilterRecipe
    var intensity: Double
    var isFavorite = false
    var updatedAt: Date
    var isDeleted = false

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, recipe, intensity, isFavorite, updatedAt, isDeleted
    }

    init(
        schemaVersion: Int = 1,
        id: UUID,
        name: String,
        recipe: FilterRecipe,
        intensity: Double,
        isFavorite: Bool = false,
        updatedAt: Date,
        isDeleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.recipe = recipe
        self.intensity = intensity
        self.isFavorite = isFavorite
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = 1
        id = try values.decode(UUID.self, forKey: .id)
        name = Self.sanitizedName(try values.decode(String.self, forKey: .name))
        recipe = try values.decode(FilterRecipe.self, forKey: .recipe).clamped()
        recipe.id = "user-\(id.uuidString)"
        intensity = min(max(try values.decode(Double.self, forKey: .intensity), 0), 1)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        isDeleted = try values.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }

    static func merged(_ local: [UserPreset], _ remote: [UserPreset]) -> [UserPreset] {
        Dictionary(grouping: local + remote, by: \.id)
            .compactMap { $0.value.max { $0.updatedAt < $1.updatedAt } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func sanitizedName(_ value: String) -> String {
        let name = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return name.isEmpty ? String(localized: "filter.untitled") : name
    }
}
