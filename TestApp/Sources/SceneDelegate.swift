//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else {
            return
        }

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = appDelegate.makeRootViewController()
        window.makeKeyAndVisible()
        self.window = window

        if let urlContext = connectionOptions.urlContexts.first {
            open(urlContext)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let urlContext = URLContexts.first else {
            return
        }

        open(urlContext)
    }

    private func open(_ urlContext: UIOpenURLContext) {
        guard
            let url = urlContext.url.anyURL.absoluteURL,
            let rootViewController = window?.rootViewController
        else {
            return
        }

        appDelegate.importPublication(from: url, sender: rootViewController)
    }

    private var appDelegate: AppDelegate {
        UIApplication.shared.delegate as! AppDelegate
    }
}
