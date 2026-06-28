import Testing
import Foundation
@testable import golos_meet

@Suite struct AppPathsTests {
    @Test func modelDirIsUnderModelsRoot() {
        let dir = AppPaths.modelDir("gigaam-v3")
        #expect(dir.lastPathComponent == "gigaam-v3")
        #expect(dir.deletingLastPathComponent().lastPathComponent == "models")
    }
}
