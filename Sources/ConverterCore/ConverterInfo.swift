// Where this converter app was built from (the Info.plist keys scripts/build_converter_app.py writes), to tell when an update of the repository changed the app itself
import Foundation

public enum ConverterInfo {
    public static var builtFromRepository: URL? { infoString("NXConverterRepository").map { URL(fileURLWithPath: $0, isDirectory: true) } }
    public static var builtFromCommit: String? { infoString("NXConverterCommit") }
    public static let sourcePaths = ["dm/mac/converter", "scripts/build_converter_app.py"]

    private static func infoString(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
