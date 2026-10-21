#!/usr/bin/env swift
// Makes an app the default handler for the given file extensions.
//   swift scripts/set-default-app.swift /Applications/Loupe.app json ndjson jsonl
import AppKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: set-default-app.swift <app> <extension>...")
    exit(2)
}
let app = URL(fileURLWithPath: args[1])
var failed = false
for ext in args.dropFirst(2) {
    guard let type = UTType(filenameExtension: ext) else {
        print("✗ .\(ext): unknown type")
        failed = true
        continue
    }
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
        if let error {
            print("✗ .\(ext) (\(type.identifier)): \(error.localizedDescription)")
            failed = true
        } else {
            print("✓ .\(ext) (\(type.identifier)) → \(app.lastPathComponent)")
        }
        done.signal()
    }
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}
exit(failed ? 1 : 0)
