//
//  GameViewController.swift
//  NPCSandbox macOS
//
//  Created by Luis Matute on 24/04/2026.
//

import Cocoa
import SpriteKit
import GameplayKit

class GameViewController: NSViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        let scene = GameScene.newGameScene()
        
        // Present the scene
        let skView = self.view as! SKView
        skView.presentScene(scene)
        
        skView.ignoresSiblingOrder = true

        skView.showsFPS = true
        skView.showsNodeCount = true
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Route keyDown to the scene so its overrides fire (e.g. J to toggle
        // the journal). viewDidLoad's window is nil; this is the first hook
        // where it's safe to assign first responder.
        if let scene = (view as? SKView)?.scene {
            view.window?.makeFirstResponder(scene)
        }
    }

}

