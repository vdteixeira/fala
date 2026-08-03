/// Ajustes › Privacidade — the tab with no controls.
///
/// DESIGN-HANDOFF.md §1 calls it "the emotional core"; the mockup's footer marks
/// the lock+waveform illustration decorative and everything else FUNCTIONAL
/// content. It is the product's central claim written down where a user can go
/// and read it, so the copy is pinned by tests the same way a behaviour would be:
/// a release that quietly softened "Nenhum áudio, texto ou métrica de uso é
/// enviado" into something hedged would be changing the promise, not the wording.
///
/// Every sentence is the mockup's, verbatim.
public enum PrivacyPane {

  /// The headline under the mark.
  public static let headline = "Sua voz não sai do seu Mac."

  public static let body =
    "Todo o reconhecimento acontece no chip do seu Mac. Nenhum áudio, texto ou "
    + "métrica de uso é enviado a servidores — nem nossos, nem de terceiros."

  /// One reassurance row: an accent-tinted symbol and a line of copy.
  public struct Row: Sendable, Equatable, Identifiable {
    public let id: String
    public let symbol: String
    public let text: String

    public init(id: String, symbol: String, text: String) {
      self.id = id
      self.symbol = symbol
      self.text = text
    }
  }

  /// The three rows, in the mockup's order.
  public static let rows: [Row] = [
    Row(
      id: "local",
      symbol: FalaSymbol.processor,
      text: "Processamento 100% local, no Apple Silicon"),
    Row(
      id: "offline",
      symbol: FalaSymbol.offline,
      text: "Funciona offline · sem telemetria, sem contas"),
    Row(
      id: "lgpd",
      symbol: FalaSymbol.verifiedShield,
      text: "Alinhado à LGPD: seus dados nunca são coletados"),
  ]

  /// The trust badge at the bottom.
  ///
  /// Its text is `MenuBarStrings.privacyFooter` rather than a second copy: the
  /// popover shows the same claim in its fixed footer, and two literals would
  /// let one of them be reworded alone.
  public static var badgeText: String { MenuBarStrings.privacyFooter }
  public static let badgeSymbol = FalaSymbol.secureField

  /// The decorative mark: a shield with a contained waveform under it.
  /// Decorative per the mockup's own footer, so it is hidden from VoiceOver and
  /// the headline carries the meaning.
  public static let markSymbol = FalaSymbol.privacyShield
}
