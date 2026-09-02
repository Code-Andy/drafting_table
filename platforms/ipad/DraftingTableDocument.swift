import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let draftingTableDocument = UTType(exportedAs: "com.local.draftingtable.document",
                                               conformingTo: .data)
}

/// Flat Files document containing one bounded, versioned DTAR archive.
/// UIDocument supplies coordinated reads/writes and safe replacement. The
/// engine still validates the archive transactionally before accepting it.
final class DraftingTableDocument: UIDocument {
    var archiveData = Data()

    override func contents(forType typeName: String) throws -> Any {
        archiveData
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        if let data = contents as? Data {
            archiveData = data
        } else if let wrapper = contents as? FileWrapper,
                  wrapper.isRegularFile,
                  let data = wrapper.regularFileContents {
            archiveData = data
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
