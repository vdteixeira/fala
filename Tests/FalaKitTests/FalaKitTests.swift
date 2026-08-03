import Testing

@testable import FalaKit

/// `scripts/ship.sh` extracts this string with
/// `sed -n 's/.*version = "\(.*\)"/\1/p'` and names `dist/Fala-<version>.dmg`
/// from it, so what matters is that it stays present and parseable — not what
/// today's number happens to be.
///
/// It used to assert the literal "0.1.0", which meant every release broke a test
/// that had never checked anything: an empty or malformed version would have
/// passed just as happily on the day it was written.
@Test func versionIsShippableSemver() {
  let parts = FalaKitInfo.version.split(separator: ".", omittingEmptySubsequences: false)
  #expect(parts.count == 3, "not semver: \(FalaKitInfo.version)")
  #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
  // A path component, and a DMG filename: neither may carry whitespace.
  #expect(!FalaKitInfo.version.contains { $0.isWhitespace })
}
