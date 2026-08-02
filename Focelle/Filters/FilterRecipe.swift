import Foundation

struct FilterRecipe: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var nameKey: String
    var exposure: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var fade: Double = 0
    var grain: Double = 0
    var vignette: Double = 0
    var monochrome = false

    func clamped() -> FilterRecipe {
        var value = self
        value.exposure = min(max(exposure, -1), 1)
        value.highlights = min(max(highlights, -1), 1)
        value.shadows = min(max(shadows, -1), 1)
        value.contrast = min(max(contrast, -1), 1)
        value.saturation = min(max(saturation, -1), 1)
        value.warmth = min(max(warmth, -1), 1)
        value.tint = min(max(tint, -1), 1)
        value.fade = min(max(fade, 0), 1)
        value.grain = min(max(grain, 0), 1)
        value.vignette = min(max(vignette, 0), 1)
        return value
    }
}

enum FocelleOriginals {
    static let all: [FilterRecipe] = [
        .init(
            id: "neutral-skin", nameKey: "filter.neutralSkin", highlights: -0.08, shadows: 0.08, saturation: -0.03,
            warmth: 0.04),
        .init(
            id: "clean-bright", nameKey: "filter.cleanBright", exposure: 0.18, highlights: -0.12, shadows: 0.12,
            contrast: 0.04, saturation: 0.03),
        .init(
            id: "soft-portrait", nameKey: "filter.softPortrait", exposure: 0.08, highlights: -0.18, shadows: 0.16,
            contrast: -0.10, saturation: -0.06, warmth: 0.08, fade: 0.05),
        .init(
            id: "warm-glow", nameKey: "filter.warmGlow", exposure: 0.08, highlights: -0.10, shadows: 0.08,
            contrast: 0.04, saturation: 0.08, warmth: 0.28, tint: 0.05),
        .init(
            id: "golden-hour", nameKey: "filter.goldenHour", exposure: -0.04, highlights: -0.16, shadows: 0.10,
            contrast: 0.10, saturation: 0.12, warmth: 0.42, tint: 0.08, vignette: 0.10),
        .init(
            id: "cafe-amber", nameKey: "filter.cafeAmber", exposure: -0.08, highlights: -0.20, shadows: 0.08,
            contrast: 0.14, saturation: -0.02, warmth: 0.34, tint: 0.10, fade: 0.06, vignette: 0.12),
        .init(
            id: "travel-vivid", nameKey: "filter.travelVivid", exposure: 0.04, highlights: -0.10, shadows: 0.05,
            contrast: 0.16, saturation: 0.24, warmth: 0.04),
        .init(
            id: "cool-air", nameKey: "filter.coolAir", exposure: 0.08, highlights: -0.08, shadows: 0.12, contrast: 0.05,
            saturation: -0.04, warmth: -0.25, tint: -0.04),
        .init(
            id: "night-neon", nameKey: "filter.nightNeon", exposure: -0.10, highlights: -0.24, shadows: 0.16,
            contrast: 0.22, saturation: 0.30, warmth: -0.14, tint: 0.22, vignette: 0.18),
        .init(
            id: "faded-film", nameKey: "filter.fadedFilm", exposure: 0.04, highlights: -0.18, shadows: 0.14,
            contrast: -0.08, saturation: -0.16, warmth: 0.12, tint: 0.04, fade: 0.22, grain: 0.12),
        .init(
            id: "matte-grain", nameKey: "filter.matteGrain", exposure: -0.02, highlights: -0.16, shadows: 0.18,
            contrast: 0.02, saturation: -0.12, warmth: 0.06, fade: 0.18, grain: 0.24, vignette: 0.08),
        .init(
            id: "mono-contrast", nameKey: "filter.monoContrast", highlights: -0.12, shadows: 0.08, contrast: 0.28,
            grain: 0.10, vignette: 0.14, monochrome: true),
    ]
}

struct PresetDraft: Codable, Equatable {
    let base: FilterRecipe
    var recipe: FilterRecipe
    var intensity: Double

    init(base: FilterRecipe) {
        self.base = base
        recipe = base
        intensity = 1
    }

    mutating func setToneColor(tone: Double, color: Double) {
        recipe.exposure = min(max(tone, -1), 1) * 0.35
        recipe.warmth = min(max(color, -1), 1) * 0.5
    }

    mutating func reset() {
        recipe = base
        intensity = 1
    }
}
