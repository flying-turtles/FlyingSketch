import Foundation
import Testing
import SketchCore
@testable import PartsKit

@Suite struct ErrorMessageTests {
    @Test func libraryErrorsAreReadable() {
        let errors: [Error] = [
            PersonalLibraryError.escapesRoot("x"), PersonalLibraryError.invalidStudioFile("a.txt"),
            PersonalLibraryError.notPersonal("x"), PersonalLibraryError.studioDownloading("x"),
            ZipError.notAZip, PartImportError.noFzp, SVGError.notSVG,
            DocumentError.missingDocumentJSON, AssetNameError.unsafe("../x"), PartDefinitionError.geometryOutOfRange,
        ]
        for error in errors {
            let text = error.localizedDescription
            #expect(!text.contains("error "), "raw text: \(text)")
            #expect(text.hasSuffix("."))
        }
        #expect(PersonalLibraryError.invalidStudioFile("a.txt").localizedDescription.contains("a.txt"))
    }
}
