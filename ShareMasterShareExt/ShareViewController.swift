//
//  ShareViewController.swift
//  ShareMasterShareExt
//
//  Principal class of the share extension. Hosts the SwiftUI upload flow:
//  pick a destination → upload → link on the clipboard → auto-dismiss.
//

import UIKit
import SwiftUI

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        // The extension process survives between share-sheet presentations,
        // so pick up any account/destination edits made in the main app.
        ConfigStore.shared.reloadFromDefaults()

        let rootView = ShareUploadView(
            extensionItems: (extensionContext?.inputItems as? [NSExtensionItem]) ?? [],
            onFinish: { [weak self] error in
                if let error {
                    self?.extensionContext?.cancelRequest(withError: error)
                } else {
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
            }
        )

        let host = UIHostingController(rootView: rootView)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
