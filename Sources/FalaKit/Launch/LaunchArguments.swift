import Foundation

/// The arguments the USER meant, with the ones macOS injects removed.
///
/// **Why this exists, and why FR-19 needs it.** `main.swift` picks the app's
/// mode from `argv` and treats "no argument" as `menubar`; anything it does not
/// recognise falls through to the usage text and the process exits. A login item
/// is launched by launchd/LaunchServices rather than by a shell, and that path
/// can put arguments in front of the user's — historically `-psn_0_<n>` (the
/// Carbon process serial number), and `-NS…` / `-Apple…` key/value pairs from
/// `NSUserDefaults` when a debugger or a defaults write is involved. Any one of
/// them turns the boot launch into a process that prints a usage message nobody
/// can see and quits, i.e. autostart that silently does nothing.
///
/// Filtering them is cheap and cannot cost anything: every flag Fala itself
/// defines (FR-21: `--hotkey`, `--no-overlay`, `--model`, `--version`) is
/// double-dashed, so no real argument can collide with these prefixes.
public enum LaunchArguments {

  /// LaunchServices' process serial number. Carries no value of its own.
  static let processSerialNumberPrefix = "-psn_"

  /// `NSUserDefaults`-style injected pairs: the flag is followed by its value,
  /// so both have to be dropped (`-NSDocumentRevisionsDebugMode YES`).
  static let injectedPairPrefixes = ["-NS", "-Apple"]

  /// Drops `argv[0]` and everything the system added.
  ///
  /// The default reads the real command line, so the executable's one-line
  /// change is `let arguments = LaunchArguments.user()`.
  public static func user(_ commandLine: [String] = CommandLine.arguments) -> [String] {
    sanitize(Array(commandLine.dropFirst()))
  }

  /// The same filter over arguments that have already had `argv[0]` removed.
  public static func sanitize(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument.hasPrefix(processSerialNumberPrefix) {
        index += 1
      } else if injectedPairPrefixes.contains(where: argument.hasPrefix) {
        // Skip the flag and its value. `min` guards the malformed case where the
        // injected flag is last and has no value at all.
        index = min(index + 2, arguments.endIndex)
      } else {
        result.append(argument)
        index += 1
      }
    }
    return result
  }
}
