//
//  IntentContext.swift
//  RouterWatch
//

import Foundation

/// The object graph an App Intent works against.
///
/// Intents run in a launch of their own — Shortcuts, Siri, or a Home-screen
/// button can start the app in the background purely to perform one — so they
/// cannot assume a window ever appeared. Going through here gives every intent
/// the same prepared graph, and lets tests substitute one that reads and writes
/// a temporary directory instead of the user's real logs.
@MainActor
enum IntentContext {

    private static var override: AppEnvironment?

    static var environment: AppEnvironment {
        override ?? .shared
    }

    /// Prepared on demand: an intent may be the reason the app launched at all.
    static func preparedEnvironment() -> AppEnvironment {
        let environment = environment
        environment.prepareData()
        return environment
    }

    /// Tests only.
    static func setEnvironment(_ environment: AppEnvironment?) {
        override = environment
    }
}
