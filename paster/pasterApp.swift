//
//  pasterApp.swift
//  paster
//
//  Created by yinminqian on 21/8/2026.
//

import SwiftUI
import CoreData

@main
struct pasterApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
