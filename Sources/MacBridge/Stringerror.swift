// MacBridge/Sources/MacBridge/StringError.swift
// Lets plain String be used as the failure type in Result<_, String>,
// which Mail.swift, Safari.swift, and System.swift all rely on for their
// runScript(_:) helpers. Centralized here instead of duplicated per-file.

import Foundation

extension String: Error {}