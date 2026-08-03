import Testing

@testable import FalaKit

/// The Ajustes window's shell and its one purely static tab.
///
/// Everything here is content the mockup fixes and that has no other way of
/// being checked: a tab strip cannot be diffed against a screenshot in CI, and
/// the Privacidade copy is a promise rather than a label.
@Suite("SettingsTab")
struct SettingsTabTests {

  /// The mockup's `tabDefs` array, in its order. A reorder is a visual change to
  /// a window nobody has screenshotted yet, so it has to fail here.
  @Test("The five tabs are the mockup's, in the mockup's order")
  func tabOrderMatchesTheMockup() {
    let titles = SettingsTab.allCases.map(\.title)
    #expect(titles == ["Geral", "Áudio", "Dicionário", "Modelo", "Privacidade"])
  }

  /// The tab glyphs come from the handoff's icon map (§5), not from a second
  /// hand-written list — so a change to `FalaSymbol` moves the tab strip too.
  @Test("Every tab icon is the handoff's SF Symbol substitution")
  func tabSymbolsComeFromTheIconMap() {
    #expect(SettingsTab.general.symbol == FalaSymbol.settings)
    #expect(SettingsTab.audio.symbol == FalaSymbol.idle)
    #expect(SettingsTab.dictionary.symbol == FalaSymbol.dictionary)
    #expect(SettingsTab.model.symbol == FalaSymbol.processor)
    #expect(SettingsTab.privacy.symbol == FalaSymbol.privacyShield)
  }

  /// HIG, not the mockup: a settings window has to be reachable from the
  /// keyboard. ⌘1…⌘5 is what every tabbed macOS settings window binds.
  @Test("Tabs bind ⌘1 through ⌘5, in order")
  func tabsBindDigitShortcuts() {
    #expect(SettingsTab.allCases.compactMap(\.shortcutKey) == ["1", "2", "3", "4", "5"])
  }

  @Test("Each tab tells VoiceOver its position in the strip")
  func tabsAnnounceTheirPosition() {
    #expect(SettingsTab.general.accessibilityLabel == "Geral, aba 1 de 5")
    #expect(SettingsTab.privacy.accessibilityLabel == "Privacidade, aba 5 de 5")
  }

  @Test("The window title carries the one brand-name constant")
  func windowTitleUsesTheBrandConstant() {
    #expect(SettingsStrings.windowTitle == "Ajustes — Fala")
    #expect(SettingsStrings.windowTitle.hasSuffix(MenuBarStrings.brandName))
  }

  @Test("The window is the mockup's 520pt")
  func windowWidthMatchesTheMockup() {
    #expect(SettingsLayout.windowWidth == 520)
    #expect(SettingsLayout.contentMinHeight == 240)
  }
}

@Suite("SettingsTabBar")
struct SettingsTabBarTests {

  @Test("Exactly one item is selected, and it is the one asked for")
  func oneItemIsSelected() {
    var bar = SettingsTabBar(selected: .general)
    #expect(bar.items.filter(\.isSelected).map(\.tab) == [.general])
    bar.select(.model)
    #expect(bar.items.filter(\.isSelected).map(\.tab) == [.model])
    #expect(bar.items.count == SettingsTab.allCases.count)
  }

  /// The view crossfades on a REAL change only. Returning true for a re-click
  /// would re-run a 200 ms animation over identical content every time the user
  /// clicked the tab they are already on.
  @Test("Re-selecting the current tab reports no change")
  func reselectingReportsNoChange() {
    var bar = SettingsTabBar(selected: .audio)
    #expect(bar.select(.audio) == false)
    #expect(bar.select(.privacy) == true)
  }

  @Test("⌃⇥ walks forward and wraps; ⌃⇧⇥ walks back and wraps")
  func advanceWraps() {
    var bar = SettingsTabBar(selected: .privacy)
    bar.advance(by: 1)
    #expect(bar.selected == .general)
    bar.advance(by: -1)
    #expect(bar.selected == .privacy)
    bar.advance(by: -1)
    #expect(bar.selected == .model)
  }
}

@Suite("SettingsWindowModel")
@MainActor
struct SettingsWindowModelTests {

  @Test("The window opens on Geral")
  func opensOnGeneral() {
    #expect(SettingsWindowModel().selected == .general)
  }

  @Test("Selecting reports whether anything moved")
  func selectionReportsMovement() {
    let model = SettingsWindowModel()
    #expect(model.select(.dictionary))
    #expect(model.selected == .dictionary)
    #expect(!model.select(.dictionary))
  }

  @Test("⌃⇥ walks the tabs through the window model too")
  func advanceWalksTabs() {
    let model = SettingsWindowModel(selected: .model)
    model.advance(by: 1)
    #expect(model.selected == .privacy)
    model.advance(by: 1)
    #expect(model.selected == .general)
  }

  /// THE reason visibility is modelled at all: the Áudio tab holds the
  /// microphone open while it is showing, and the cost of getting this wrong is
  /// an open microphone over a window the user believes they closed. It is a
  /// stated fact, not a guess about when a hosted view "disappeared".
  @Test("Visibility is explicit, starts closed, and does not repeat itself")
  func visibilityIsExplicit() {
    let model = SettingsWindowModel()
    #expect(!model.isVisible)
    model.setVisible(true)
    #expect(model.isVisible)
    model.setVisible(true)
    #expect(model.isVisible)
    model.setVisible(false)
    #expect(!model.isVisible)
  }

  /// Reopening must put the window back in a live state — a second `show()`
  /// after a close is the flow that a released window would have crashed on.
  @Test("A closed window can be shown again")
  func visibilityRoundTrips() {
    let model = SettingsWindowModel()
    model.setVisible(true)
    model.setVisible(false)
    model.setVisible(true)
    #expect(model.isVisible)
  }
}

/// The Privacidade tab is the product's central claim, printed where a user can
/// go and read it. Pinning the copy is pinning the promise: a release that
/// hedged "Nenhum áudio … é enviado" would be changing what the app says it
/// does, and no screenshot review would catch a softened adverb.
@Suite("PrivacyPane")
struct PrivacyPaneTests {

  @Test("The headline and body are the mockup's, verbatim")
  func copyIsTheMockups() {
    #expect(PrivacyPane.headline == "Sua voz não sai do seu Mac.")
    #expect(PrivacyPane.body.contains("Todo o reconhecimento acontece no chip do seu Mac."))
    #expect(PrivacyPane.body.contains("nem nossos, nem de terceiros"))
  }

  @Test("The three reassurance rows are present, in order, with the mapped symbols")
  func reassuranceRows() {
    #expect(PrivacyPane.rows.count == 3)
    let symbols = PrivacyPane.rows.map(\.symbol)
    #expect(symbols == [FalaSymbol.processor, FalaSymbol.offline, FalaSymbol.verifiedShield])
    #expect(PrivacyPane.rows[0].text.contains("Apple Silicon"))
    #expect(PrivacyPane.rows[1].text.contains("offline"))
    #expect(PrivacyPane.rows[2].text.contains("LGPD"))
  }

  /// One claim, one literal. The popover's fixed footer says the same sentence,
  /// and two copies would let a reword touch only one surface.
  @Test("The trust badge is the popover's privacy line, not a second copy")
  func badgeSharesThePopoverLine() {
    #expect(PrivacyPane.badgeText == MenuBarStrings.privacyFooter)
    #expect(PrivacyPane.badgeText == "100% no seu Mac · sem telemetria")
  }

  /// NFR-1 is a hard product constraint, so the tab must not contain a word that
  /// walks it back. This is a smoke test for the promise, not for the prose.
  @Test("Nothing on the tab hedges the no-network claim")
  func nothingHedgesTheClaim() {
    var lines = [PrivacyPane.headline, PrivacyPane.body, PrivacyPane.badgeText]
    lines += PrivacyPane.rows.map(\.text)
    let text = lines.joined(separator: " ").lowercased()
    for hedge in ["opcional", "por padrão", "anônim", "quando possível", "salvo"] {
      #expect(!text.contains(hedge), "'\(hedge)' weakens the privacy claim")
    }
  }
}
