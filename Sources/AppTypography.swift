import CoreText
import SwiftUI

enum AppTypography {
    private enum Face: String, CaseIterable {
        case regular = "Regular"
        case medium = "Medium"
        case semibold = "SemiBold"
        case bold = "Bold"

        var postScriptName: String { "OxaniumRoman-\(rawValue)" }
        var resourceName: String { self == .bold ? "Oxanium-Bold" : postScriptName }
    }

    private static let registeredFaces = Set(Face.allCases.filter { face in
        guard let url = Bundle.main.url(forResource: face.resourceName, withExtension: "ttf", subdirectory: "Fonts") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    })

    static func registerFonts() {
        _ = registeredFaces
    }

    static func heading(size: CGFloat) -> Font {
        font(size: size, weight: .bold)
    }

    static func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let face: Face
        switch weight {
        case .medium: face = .medium
        case .semibold: face = .semibold
        case .bold, .heavy, .black: face = .bold
        default: face = .regular
        }
        guard registeredFaces.contains(face) else { return .system(size: size, weight: weight) }
        return .custom(face.postScriptName, size: size, relativeTo: .body)
    }
}

extension View {
    func appTypography() -> some View {
        font(AppTypography.font(size: 13))
    }
}
