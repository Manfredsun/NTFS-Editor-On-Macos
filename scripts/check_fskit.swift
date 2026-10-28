import Foundation
import FSKit

if #available(macOS 15.4, *) {
    Task {
        do {
            let modules = try await FSClient.shared.installedExtensions
            for module in modules {
                print("\(module.bundleIdentifier) enabled=\(module.isEnabled) path=\(module.url.path)")
            }
            exit(0)
        } catch {
            print("FSKit query failed: \(error)")
            exit(1)
        }
    }
    dispatchMain()
} else {
    print("FSKit requires macOS 15.4")
}
