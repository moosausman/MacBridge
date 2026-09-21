// MacBridge/Sources/MacBridge/Modules/AppleScript.swift
// Owns: NSAppleScript (arbitrary AppleScript execution).
// Exposes static functions returning JSON-safe [String: Any] dictionaries.
// Knows nothing about HTTP — Router.swift is the only caller.
//
// ⚠️ No sandboxing or guardrail here by design — this runs whatever script
// text is sent, with full user privileges. Anyone who can reach this HTTP
// server can run arbitrary AppleScript on this Mac. Acceptable only because
// the server binds to localhost. Do not expose this port beyond localhost.

import Foundation

enum AppleScriptModule {

    /// args: { "script": String }
    static func run(args: [String: Any]) -> [String: Any] {
        guard let source = args["script"] as? String, !source.isEmpty else {
            return ["ok": false, "error": "'script' is required"]
        }

        // Same main-thread + timeout treatment as every other AppleScript
        // path here. This route runs caller-supplied script text, so it is
        // the single most likely one to block on a permission prompt or an
        // unresponsive app -- and it holds `uiLock` while it does.
        let (result, error) = AppleScriptRunner.run(
            source,
            timeout: 45,   // caller-supplied scripts can legitimately be slow
            appName: "The script's target application"
        )

        if let error {
            return ["ok": false, "error": error]
        }
        guard let result else {
            return ["ok": false, "error": "Script returned no result"]
        }

        // `stringValue` alone is nil for lists and records, so a script like
        // `get name of every disk` used to come back as `"result": null`
        // even though it succeeded. Convert the descriptor structurally.
        return [
            "ok": true,
            "result": jsonValue(of: result)
        ]
    }

    /// Converts an AppleScript result into a JSON-safe value: lists become
    /// arrays, records become objects, numbers/booleans keep their type,
    /// and anything else falls back to its text coercion.
    private static func jsonValue(of descriptor: NSAppleEventDescriptor) -> Any {
        switch descriptor.descriptorType {
        case typeNull:
            return NSNull()
        case typeAEList:
            guard descriptor.numberOfItems > 0 else { return [Any]() }
            return (1...descriptor.numberOfItems).map { index -> Any in
                descriptor.atIndex(index).map(jsonValue(of:)) ?? NSNull()
            }
        case typeAERecord:
            var object: [String: Any] = [:]
            if descriptor.numberOfItems > 0 {
                for index in 1...descriptor.numberOfItems {
                    let keyword = descriptor.keywordForDescriptor(at: index)
                    guard let value = descriptor.atIndex(index) else { continue }
                    if keyword == AEKeyword(0x7573_7266) { // 'usrf' (keyASUserRecordFields)
                        // User-defined labels arrive as a flat [key, value, ...] list.
                        let pairs = value.numberOfItems
                        var i = 1
                        while i < pairs {
                            if let key = value.atIndex(i)?.stringValue, let item = value.atIndex(i + 1) {
                                object[key] = jsonValue(of: item)
                            }
                            i += 2
                        }
                    } else {
                        object[fourCharCode(keyword)] = jsonValue(of: value)
                    }
                }
            }
            return object
        case typeTrue:
            return true
        case typeFalse:
            return false
        case typeBoolean:
            return descriptor.booleanValue
        case typeSInt16, typeSInt32, typeSInt64, typeUInt32:
            return Int(descriptor.int32Value)
        case typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
            return descriptor.doubleValue
        default:
            return descriptor.stringValue ?? NSNull()
        }
    }

    private static func fourCharCode(_ code: AEKeyword) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespaces) ?? String(code)
    }
}