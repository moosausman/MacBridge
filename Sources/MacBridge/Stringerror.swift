// MacBridge/Sources/MacBridge/Stringerror.swift
// The failure type for the `runScript(_:) -> Result<String?, ScriptError>`
// helpers in Mail.swift, Safari.swift and System.swift.
//
// This file used to contain `extension String: Error {}` instead.
// That worked, but it's a retroactive conformance of a standard-library
// type to a standard-library protocol: it applies process-wide, so every
// String in the entire binary silently became throwable, and any other
// module doing the same thing would collide with it. Swift 5 warns about
// it; Swift 6 language mode rejects it outright, so it was a migration
// blocker sitting in a seven-line file.
//
// A named type costs nothing and says what it actually is.
import Foundation

struct ScriptError: Error, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
