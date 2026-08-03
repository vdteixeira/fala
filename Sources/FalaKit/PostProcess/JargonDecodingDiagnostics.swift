import Foundation

/// Turns a `DecodingError` from a jargon file into the Brazilian-Portuguese
/// sentence the user actually reads in `fala doctor` and the menu bar.
///
/// Foundation's decoder speaks English, and it speaks about SWIFT TYPES:
/// "Cannot initialize JargonSafety from invalid String value seguro",
/// "The given data was not valid JSON." Those strings used to be interpolated
/// verbatim into a pt-BR warning, so the one sentence whose entire job was to
/// explain the problem was half unreadable — and it never said WHICH entry
/// failed, while discarding the user's whole file.
///
/// Two things this adds that the raw decoder cannot:
/// 1. **Location.** `entries[1].to` becomes "na entrada nº 2 ('com pose')" —
///    the ordinal a human counts with, plus the entry's own `from` so the user
///    can search for it instead of counting.
/// 2. **The value they wrote.** For an invalid `safety` the decoder knows the
///    bad value but only in English prose, so it is re-read from the raw JSON
///    at the failing coding path and quoted back.
///
/// Privacy: everything quoted here comes from the dictionary file the user
/// wrote themselves. No audio, no transcript text, and nothing is logged — the
/// result is returned as a value for the caller to display.
enum JargonDecodingDiagnostic {

  /// Longest fragment of the user's own file worth quoting back. A pasted blob
  /// in `from` must not turn a one-line warning into a wall of text.
  private static let maxQuotedLength = 40

  /// - Parameters:
  ///   - error: what `JSONDecoder` threw.
  ///   - data: the bytes it was decoding, when available. Used only to look up
  ///     the offending entry's `from` and the offending value; the message
  ///     degrades gracefully to "na entrada nº 2" without it.
  static func describe(_ error: DecodingError, in data: Data? = nil) -> String {
    switch error {
    case .keyNotFound(let key, let context):
      return locate("falta a chave '\(key.stringValue)'", context.codingPath, data)

    case .typeMismatch(let type, let context):
      let detail = "\(field(context.codingPath)) deveria ser \(portugueseName(for: type))"
      return locate(detail, context.codingPath, data)

    case .valueNotFound(_, let context):
      return locate("\(field(context.codingPath)) está nulo", context.codingPath, data)

    case .dataCorrupted(let context):
      guard !context.codingPath.isEmpty else {
        return "não é JSON válido — verifique vírgulas, aspas e chaves"
      }
      return locate(corrupted(at: context.codingPath, in: data), context.codingPath, data)

    @unknown default:
      return "não foi possível ler o arquivo"
    }
  }

  // MARK: - Locating the failure

  /// Prefixes the detail with the entry it happened in, when it happened in one.
  /// A comma rather than a colon, because this string is itself interpolated
  /// into a sentence that already has one.
  private static func locate(
    _ detail: String, _ path: [any CodingKey], _ data: Data?
  ) -> String {
    guard let index = entryIndex(in: path) else { return detail }
    let named = entryName(at: index, in: data).map { " ('\($0)')" } ?? ""
    return "na entrada nº \(index + 1)\(named), \(detail)"
  }

  /// Position inside the `entries` array, or nil when the failure is elsewhere
  /// (a bad `disable`, a bad top-level shape). The flat `substitutions` map has
  /// no indices, so it correctly yields nil.
  private static func entryIndex(in path: [any CodingKey]) -> Int? {
    for (position, key) in path.enumerated() where key.stringValue == "entries" {
      if let index = path.dropFirst(position + 1).first?.intValue { return index }
    }
    return nil
  }

  /// The failing entry's `from`, read back from the raw JSON so the user can
  /// find it by searching instead of counting rows.
  private static func entryName(at index: Int, in data: Data?) -> String? {
    guard
      let value = jsonValue(
        atKeys: ["entries", String(index), "from"], in: data, indexAt: 1)
    else { return nil }
    return quoted(value)
  }

  /// What a `.dataCorrupted` at a known field means, in pt-BR. The overwhelming
  /// case in this format is a `safety` value that is not one of the three tiers,
  /// which is worth naming explicitly because the valid set is not guessable.
  private static func corrupted(at path: [any CodingKey], in data: Data?) -> String {
    let name = field(path)
    guard path.last?.stringValue == "safety" else {
      return "\(name) tem um valor inválido"
    }
    let allowed = JargonSafety.allCases.map { "'\($0.rawValue)'" }
    let listed = allowed.dropLast().joined(separator: ", ") + " ou " + (allowed.last ?? "")
    guard let written = writtenValue(at: path, in: data) else {
      return "'safety' tem um valor inválido; use \(listed)"
    }
    return "'safety' tem o valor '\(written)'; use \(listed)"
  }

  // MARK: - Naming things in Portuguese

  /// The field the error is about: a quoted JSON key, or the entry itself when
  /// the failure is on the array element rather than one of its keys.
  private static func field(_ path: [any CodingKey]) -> String {
    guard let last = path.last else { return "o arquivo" }
    if last.intValue != nil { return "a entrada" }
    return "'\(last.stringValue)'"
  }

  private static func portugueseName(for type: Any.Type) -> String {
    if type is String.Type { return "texto" }
    if type is Bool.Type { return "true ou false" }
    if type is Int.Type || type is Double.Type { return "um número" }
    let described = String(describing: type)
    if described.hasPrefix("Array<") || described.hasPrefix("[") { return "uma lista" }
    if described.hasPrefix("Dictionary<") { return "um objeto" }
    return "de outro tipo"
  }

  // MARK: - Re-reading the raw JSON

  /// The string at `path`, straight from the bytes. `JSONDecoder` has already
  /// failed by this point, so this is a separate, lenient read whose only job is
  /// to quote the user's own value back at them.
  private static func writtenValue(at path: [any CodingKey], in data: Data?) -> String? {
    guard let data, var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
    for key in path {
      if let index = key.intValue {
        guard let array = node as? [Any], array.indices.contains(index) else { return nil }
        node = array[index]
      } else {
        guard let object = node as? [String: Any], let next = object[key.stringValue] else {
          return nil
        }
        node = next
      }
    }
    guard let text = node as? String else { return nil }
    return quoted(text)
  }

  /// Same walk, driven by plain keys — `indexAt` says which of them is an array
  /// subscript. Used where there is no `CodingKey` to hand.
  private static func jsonValue(
    atKeys keys: [String], in data: Data?, indexAt: Int
  ) -> String? {
    guard let data, var node = try? JSONSerialization.jsonObject(with: data) else { return nil }
    for (position, key) in keys.enumerated() {
      if position == indexAt, let index = Int(key) {
        guard let array = node as? [Any], array.indices.contains(index) else { return nil }
        node = array[index]
      } else {
        guard let object = node as? [String: Any], let next = object[key] else { return nil }
        node = next
      }
    }
    return node as? String
  }

  /// Trimmed to one line and clipped, so a pasted paragraph cannot become the
  /// warning.
  private static func quoted(_ value: String) -> String {
    let single = value.replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard single.count > maxQuotedLength else { return single }
    return single.prefix(maxQuotedLength) + "…"
  }
}
