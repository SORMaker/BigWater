import Foundation

@main
@MainActor
enum BigWaterTests {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--pictures" {
            let folder = URL(fileURLWithPath: arguments.dropFirst().first ?? "dist/Pictures", isDirectory: true)
            do { try Pictures.save(to: folder) } catch { fputs("\(error)\n", stderr); exit(1) }
            exit(0)
        }
        let filter = arguments.first
        exit(Run.all([scheduleSuite, dataSuite, reminderSuite, appSuite], matching: filter))
    }
}
