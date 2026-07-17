import Testing
@testable import PhotoSweepCore

@Test func versionIsSet() { #expect(!PhotoSweep.version.isEmpty) }
