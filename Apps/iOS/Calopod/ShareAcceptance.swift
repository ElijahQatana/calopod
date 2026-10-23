import CloudKit
import UIKit

extension Notification.Name {
    static let feedShareAccepted = Notification.Name("feedShareAccepted")
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await ShareAcceptance.accept(metadata) }
    }
}

enum ShareAcceptance {
    /// Ignores a share for any other container.
    static func accept(_ metadata: CKShare.Metadata) async {
        guard metadata.containerIdentifier == CloudKitReader.containerID else { return }
        do {
            _ = try await CKContainer(identifier: metadata.containerIdentifier).accept(metadata)
            await MainActor.run { NotificationCenter.default.post(name: .feedShareAccepted, object: nil) }
        } catch {
            // Nothing to undo. The next read shows what the phone can see.
        }
    }
}
