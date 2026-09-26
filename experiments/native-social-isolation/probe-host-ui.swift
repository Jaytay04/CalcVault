import ExtensionFoundation
import ExtensionKit
import UIKit

@MainActor
func makeSyntheticHost(identity: AppExtensionIdentity) -> EXHostViewController {
    let controller = EXHostViewController()
    controller.configuration = EXHostViewController.Configuration(
        appExtension: identity,
        sceneID: "syntheticVaultUI"
    )
    return controller
}
