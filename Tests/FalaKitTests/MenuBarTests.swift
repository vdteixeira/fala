import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import FalaKit

// Tests for the menu-bar app's logic (TASKS.md T2.2, SPEC.md FR-15).
//
// The `NSStatusItem`, the `NSPopover` and the SwiftUI hierarchy live in
// `Sources/Fala/UI` and are NOT unit-testable (see the `swift-testing` skill):
// they need a window server, a menu bar and a signed bundle. Everything that can
// silently be WRONG was pushed down into `FalaKit` so it could be tested here —
// the capture gate, the state→icon mapping, the icon geometry, the pt-BR copy,
// and the presenter's refresh rules.

// MARK: - Test doubles

private struct MockPermissionChecker: PermissionChecking {
  var granted: Set<Permission>

  func isGranted(_ permission: Permission) -> Bool { granted.contains(permission) }
}

@MainActor
private final class MockDictationStore: DictationEnabledStoring {
  var stored: Bool?
  private(set) var saveCount = 0

  init(stored: Bool? = nil) { self.stored = stored }

  func loadDictationEnabled() -> Bool { stored ?? true }

  func saveDictationEnabled(_ enabled: Bool) {
    stored = enabled
    saveCount += 1
  }
}

private struct StubRecents: RecentTranscriptionsProviding {
  var entries: [RecentTranscription] = []

  func recent(limit: Int) async -> [RecentTranscription] { Array(entries.prefix(limit)) }
}

/// Records the limit it was asked for, so the popover's promise not to pull the
/// whole history into memory can be checked.
private actor RecordingRecents: RecentTranscriptionsProviding {
  private(set) var lastLimit: Int?

  func recent(limit: Int) async -> [RecentTranscription] {
    lastLimit = limit
    return []
  }
}

private func makeStatus(present: Bool, bytes: Int64? = 1_100_000_000) -> ModelStatus {
  ModelStatus(
    isPresent: present,
    sizeBytes: present ? bytes : nil,
    location: URL(fileURLWithPath: "/tmp/fala-tests/model"))
}

// MARK: - The switch that has to actually disable capture

@Suite struct CaptureGateTests {

  @Test("enabled: a press and its release both reach the coordinator")
  func enabledForwardsBothPhases() {
    var gate = CaptureGate()
    #expect(gate.admit(.pressed, dictationEnabled: true) == .pressed)
    #expect(gate.isCaptureInFlight)
    #expect(gate.admit(.released, dictationEnabled: true) == .released)
    #expect(!gate.isCaptureInFlight)
  }

  @Test("disabled: the press is dropped, so AudioCapture.start() is never called")
  func disabledDropsThePress() {
    var gate = CaptureGate()
    #expect(gate.admit(.pressed, dictationEnabled: false) == nil)
    #expect(!gate.isCaptureInFlight)
  }

  @Test("disabled: the release of a dropped press is dropped too")
  func disabledDropsTheMatchingRelease() {
    var gate = CaptureGate()
    _ = gate.admit(.pressed, dictationEnabled: false)
    #expect(gate.admit(.released, dictationEnabled: false) == nil)
  }

  /// The bug this whole type exists to prevent. Turning dictation off while the
  /// key is held must NOT swallow the release: `AudioCapture` would keep running
  /// with no event left that could stop it, and the microphone would stay open
  /// for the rest of the session. T1.7 shipped this exact failure once.
  @Test("toggled off mid-utterance: the release still gets through")
  func releaseSurvivesBeingDisabledMidCapture() {
    var gate = CaptureGate()
    #expect(gate.admit(.pressed, dictationEnabled: true) == .pressed)
    #expect(gate.admit(.released, dictationEnabled: false) == .released)
    #expect(!gate.isCaptureInFlight)
  }

  @Test("a release with nothing in flight is dropped")
  func strayReleaseIsDropped() {
    var gate = CaptureGate()
    #expect(gate.admit(.released, dictationEnabled: true) == nil)
    #expect(!gate.isCaptureInFlight)
  }

  @Test("turning dictation back on starts admitting presses again")
  func reenablingResumesCapture() {
    var gate = CaptureGate()
    #expect(gate.admit(.pressed, dictationEnabled: false) == nil)
    #expect(gate.admit(.pressed, dictationEnabled: true) == .pressed)
    #expect(gate.admit(.released, dictationEnabled: true) == .released)
  }

  @Test("a full alternating sequence never leaves a capture in flight")
  func alternatingSequenceEndsClean() {
    var gate = CaptureGate()
    for enabled in [true, false, true, true, false] {
      _ = gate.admit(.pressed, dictationEnabled: enabled)
      _ = gate.admit(.released, dictationEnabled: enabled)
    }
    #expect(!gate.isCaptureInFlight)
  }
}

@MainActor
@Suite struct DictationSwitchTests {

  @Test("first run defaults to ON, not to the Bool default of false")
  func firstRunIsEnabled() {
    let store = MockDictationStore(stored: nil)
    #expect(DictationSwitch(store: store).isEnabled)
  }

  @Test("a stored OFF survives the relaunch")
  func storedValueWins() {
    let store = MockDictationStore(stored: false)
    #expect(!DictationSwitch(store: store).isEnabled)
  }

  @Test("toggling flips the value and persists it")
  func togglePersists() {
    let store = MockDictationStore(stored: true)
    let dictation = DictationSwitch(store: store)
    dictation.toggle()
    #expect(!dictation.isEnabled)
    #expect(store.stored == false)
    #expect(store.saveCount == 1)
  }

  @Test("setting the value it already has writes nothing")
  func redundantSetIsIgnored() {
    let store = MockDictationStore(stored: true)
    let dictation = DictationSwitch(store: store)
    dictation.setEnabled(true)
    #expect(store.saveCount == 0)
  }

  @Test("the header subtitle is the mockup's pt-BR copy")
  func statusLabelIsPortuguese() {
    let dictation = DictationSwitch(store: MockDictationStore(stored: true))
    #expect(dictation.statusLabel == "Ditado ativado")
    dictation.toggle()
    #expect(dictation.statusLabel == "Ditado desativado")
  }
}

// MARK: - Status icon

@Suite struct MenuBarIconVariantTests {

  @Test("idle follows the switch")
  func idleFollowsTheSwitch() {
    #expect(MenuBarIconVariant.variant(for: .idle, dictationEnabled: true) == .idle)
    #expect(MenuBarIconVariant.variant(for: .idle, dictationEnabled: false) == .disabled)
  }

  /// The icon must never claim dictation is off while the microphone is open.
  @Test("recording outranks disabled — a live microphone is never drawn as off")
  func recordingOutranksDisabled() {
    #expect(MenuBarIconVariant.variant(for: .recording, dictationEnabled: false) == .recording)
  }

  @Test("transcribing is its own variant")
  func transcribingIsWorking() {
    let state = DictationState.transcribing(capturedSeconds: 3)
    #expect(MenuBarIconVariant.variant(for: state, dictationEnabled: true) == .working)
  }

  /// The pill owns success (1.2s) and error (2.5s) and dismisses them; the menu
  /// bar has no timer, so encoding them would freeze the last outcome up there.
  @Test("success and failure fall back to the resting icon")
  func terminalStatesReadAsIdle() {
    #expect(MenuBarIconVariant.variant(for: .success, dictationEnabled: true) == .idle)
    let failure = DictationState.failure(message: "Campo protegido — injeção bloqueada.")
    #expect(MenuBarIconVariant.variant(for: failure, dictationEnabled: true) == .idle)
    #expect(MenuBarIconVariant.variant(for: failure, dictationEnabled: false) == .disabled)
  }

  @Test("amplitude is what carries the state in a template image")
  func amplitudeOrdersTheVariants() {
    #expect(MenuBarIconVariant.idle.amplitude == 0)
    #expect(MenuBarIconVariant.disabled.amplitude == 0)
    #expect(MenuBarIconVariant.idle.amplitude < MenuBarIconVariant.working.amplitude)
    #expect(MenuBarIconVariant.working.amplitude < MenuBarIconVariant.recording.amplitude)
    #expect(MenuBarIconVariant.recording.amplitude == 1)
  }

  @Test("only the disabled variant dims the button")
  func onlyDisabledAppearsDisabled() {
    for variant in MenuBarIconVariant.allCases {
      #expect(variant.appearsDisabled == (variant == .disabled))
    }
  }

  @Test("every variant has a distinct pt-BR VoiceOver label")
  func labelsAreDistinctAndPortuguese() {
    let labels = MenuBarIconVariant.allCases.map(\.accessibilityLabel)
    #expect(Set(labels).count == MenuBarIconVariant.allCases.count)
    #expect(labels.allSatisfy { $0.hasPrefix("Fala — ") })
  }
}

@Suite struct StatusIconMarkTests {
  private let box = CGRect(x: 0, y: 0, width: 16, height: 16)

  @Test("four bars, in the mockup's proportions, at rest")
  func restingProportionsMatchTheMockup() {
    let mark = StatusIconMark.geometry(in: box, amplitude: 0)
    #expect(mark.bars.count == 4)
    // menubar-popover.dc.html:44-47 — heights 6/12/9/5 at width 2.5.
    #expect(mark.bars.map(\.height) == [6, 12, 9, 5])
    #expect(mark.bars.allSatisfy { $0.width == 2.5 })
  }

  @Test("bars are evenly spaced, left to right, and exactly fill the width")
  func spacingIsUniform() {
    let mark = StatusIconMark.geometry(in: box, amplitude: 0)
    let gaps = zip(mark.bars.dropFirst(), mark.bars).map { $0.minX - $1.maxX }
    #expect(gaps.allSatisfy { abs($0 - StatusIconMark.barGap) < 0.001 })
    #expect(abs(mark.bars[0].minX - box.minX) < 0.001)
    #expect(abs((mark.bars.last?.maxX ?? 0) - box.maxX) < 0.001)
  }

  @Test("every bar stays inside the box at both amplitudes")
  func barsNeverClip() {
    for amplitude in [0.0, 0.5, 1.0] {
      let mark = StatusIconMark.geometry(in: box, amplitude: amplitude)
      for bar in mark.bars {
        #expect(bar.minY >= box.minY - 0.001)
        #expect(bar.maxY <= box.maxY + 0.001)
        #expect(bar.minX >= box.minX - 0.001)
        #expect(bar.maxX <= box.maxX + 0.001)
      }
    }
  }

  /// A status item that changed width while recording would shove every icon to
  /// its left along the menu bar.
  @Test("amplitude changes height only, never width")
  func amplitudeDoesNotChangeWidth() {
    let resting = StatusIconMark.geometry(in: box, amplitude: 0)
    let peak = StatusIconMark.geometry(in: box, amplitude: 1)
    #expect(resting.bars.map(\.minX) == peak.bars.map(\.minX))
    #expect(resting.bars.map(\.width) == peak.bars.map(\.width))
    for (rest, loud) in zip(resting.bars, peak.bars) {
      #expect(loud.height > rest.height)
    }
  }

  @Test("at full amplitude the tallest bar fills the box")
  func peakFillsTheBox() {
    let peak = StatusIconMark.geometry(in: box, amplitude: 1)
    #expect(abs((peak.bars.map(\.height).max() ?? 0) - box.height) < 0.001)
  }

  @Test("bars are centred vertically")
  func barsAreCentred() {
    let mark = StatusIconMark.geometry(in: box, amplitude: 0.5)
    for bar in mark.bars {
      #expect(abs(bar.midY - box.midY) < 0.001)
    }
  }

  @Test("amplitude is clamped, so a bad caller cannot draw outside the box")
  func amplitudeIsClamped() {
    #expect(
      StatusIconMark.geometry(in: box, amplitude: -5).bars
        == StatusIconMark.geometry(in: box, amplitude: 0).bars)
    #expect(
      StatusIconMark.geometry(in: box, amplitude: 99).bars
        == StatusIconMark.geometry(in: box, amplitude: 1).bars)
  }

  @Test("the mark scales uniformly and stays centred in a bigger box")
  func scalesUniformly() {
    let big = CGRect(x: 10, y: 20, width: 32, height: 32)
    let mark = StatusIconMark.geometry(in: big, amplitude: 0)
    #expect(mark.bars.map(\.height) == [12, 24, 18, 10])
    #expect(mark.cornerRadius == StatusIconMark.barCornerRadius * 2)
    #expect(abs(mark.bars[0].minX - big.minX) < 0.001)
  }

  @Test("a degenerate rect draws nothing instead of dividing by zero")
  func emptyRectIsSafe() {
    #expect(StatusIconMark.geometry(in: .zero, amplitude: 1).bars.isEmpty)
  }

  @Test("the status item is square, so the mark never shifts the menu bar")
  func statusItemBoxIsSquare() {
    #expect(StatusIconMark.statusItemSize.width == StatusIconMark.statusItemSize.height)
    #expect(StatusIconMark.naturalSize.width == StatusIconMark.naturalSize.height)
  }
}

@Suite struct CSSGradientAngleTests {

  @Test("0deg paints upward — CSS measures clockwise from 'to top'")
  func zeroDegreesPointsUp() {
    let points = CSSGradientAngle.unitPoints(degrees: 0)
    #expect(abs(points.start.y - 1) < 0.001)
    #expect(abs(points.end.y - 0) < 0.001)
    #expect(abs(points.start.x - 0.5) < 0.001)
  }

  @Test("180deg paints downward")
  func oneEightyPointsDown() {
    let points = CSSGradientAngle.unitPoints(degrees: 180)
    #expect(abs(points.start.y - 0) < 0.001)
    #expect(abs(points.end.y - 1) < 0.001)
  }

  @Test("90deg paints left to right")
  func ninetyPointsRight() {
    let points = CSSGradientAngle.unitPoints(degrees: 90)
    #expect(abs(points.start.x - 0) < 0.001)
    #expect(abs(points.end.x - 1) < 0.001)
    #expect(abs(points.start.y - 0.5) < 0.001)
  }

  @Test("the lockup's 160deg runs down and to the right, as in the mockup")
  func brandAngleRunsDownRight() {
    let points = CSSGradientAngle.unitPoints(degrees: 160)
    #expect(points.end.y > points.start.y)
    #expect(points.end.x > points.start.x)
  }
}

// MARK: - Recentes

@Suite struct RecentTranscriptionTests {

  @Test("pt-BR ages match the mockup's wording")
  func agesArePortuguese() {
    #expect(RelativeTimePtBR.describe(0) == "agora")
    #expect(RelativeTimePtBR.describe(59) == "agora")
    #expect(RelativeTimePtBR.describe(60) == "há 1 min")
    #expect(RelativeTimePtBR.describe(120) == "há 2 min")
    #expect(RelativeTimePtBR.describe(3599) == "há 59 min")
    #expect(RelativeTimePtBR.describe(3600) == "há 1 h")
    #expect(RelativeTimePtBR.describe(86_399) == "há 23 h")
    #expect(RelativeTimePtBR.describe(86_400) == "há 1 d")
  }

  @Test("a clock that moved backwards reads as 'agora', never as a negative age")
  func negativeAgesAreClamped() {
    #expect(RelativeTimePtBR.describe(-5000) == "agora")
  }

  @Test("the meta line is 'há 2 min · VS Code'")
  func metaLineMatchesTheMockup() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let entry = RecentTranscription(
      text: "Vou revisar o pull request depois do almoço.",
      createdAt: now.addingTimeInterval(-120),
      destinationApp: "VS Code")
    #expect(entry.metaLine(relativeTo: now) == "há 2 min · VS Code")
  }

  @Test("an unknown destination app leaves the separator out")
  func metaLineWithoutApp() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let entry = RecentTranscription(text: "oi", createdAt: now, destinationApp: nil)
    #expect(entry.metaLine(relativeTo: now) == "agora")
    let blank = RecentTranscription(text: "oi", createdAt: now, destinationApp: "")
    #expect(blank.metaLine(relativeTo: now) == "agora")
  }

  /// A dictation containing a line break would otherwise render as its first
  /// line with no ellipsis — the rest disappears silently rather than visibly.
  @Test("the preview collapses newlines instead of hiding the rest of the text")
  func previewCollapsesWhitespace() {
    let entry = RecentTranscription(
      text: "primeira linha\n\nsegunda   linha", createdAt: .init())
    #expect(entry.previewText() == "primeira linha segunda linha")
  }

  @Test("the preview truncates with an ellipsis")
  func previewTruncates() {
    let entry = RecentTranscription(text: String(repeating: "a", count: 200), createdAt: .init())
    let preview = entry.previewText(maxCharacters: 10)
    #expect(preview.count == 11)
    #expect(preview.hasSuffix("…"))
  }

  @Test("a zero-length preview is empty, not a crash")
  func previewHandlesZero() {
    let entry = RecentTranscription(text: "qualquer coisa", createdAt: .init())
    #expect(entry.previewText(maxCharacters: 0).isEmpty)
  }

  @Test("the shipped provider vends nothing — history is T2.5, not this task")
  func stubProviderIsEmpty() async {
    let entries = await NoRecentTranscriptions().recent(limit: 4)
    #expect(entries.isEmpty)
  }
}

// MARK: - Commands, shortcuts and the rows that advertise them

/// The Phase 2 review found the popover printing "⌘ Q" and "⌘ ," while the app
/// bound neither key: the hints were literals in the view and no `NSMenu`
/// existed. Both now come from `MenuBarCommand`, and these tests are what stops
/// them drifting apart again. What CANNOT be tested here is the `NSMenu` itself
/// (AppKit, no window server) — see the notes in `FalaMainMenu`.
@Suite struct MenuBarCommandTests {

  @Test("the two shortcuts the popover advertises are ⌘Q and ⌘,")
  func shortcutsAreBound() {
    #expect(MenuBarCommand.quit.shortcut == MenuBarShortcut("q"))
    #expect(MenuBarCommand.openSettings.shortcut == MenuBarShortcut(","))
    // Histórico has none in the mockup; inventing one would add a third
    // shortcut to remember.
    #expect(MenuBarCommand.openHistory.shortcut == nil)
  }

  @Test("the hint the row prints is derived from the key the app binds")
  func hintsCannotDriftFromTheBinding() {
    #expect(MenuBarStrings.quitShortcut == MenuBarCommand.quit.shortcut?.display)
    #expect(
      MenuBarStrings.openSettingsShortcut == MenuBarCommand.openSettings.shortcut?.display)
    #expect(MenuBarStrings.quitShortcut == "⌘ Q")
    #expect(MenuBarStrings.openSettingsShortcut == "⌘ ,")
  }

  @Test("the key equivalent AppKit gets is lowercase, the printed one is not")
  func keyEquivalentIsLowercase() {
    #expect(MenuBarShortcut("Q").keyEquivalent == "q")
    #expect(MenuBarShortcut("Q").display == "⌘ Q")
    #expect(MenuBarShortcut(",").keyEquivalent == ",")
    #expect(MenuBarShortcut(",").display == "⌘ ,")
  }

  /// `NSMenuItem.tag` defaults to 0, so no command may use it: an item nobody
  /// configured must never resolve to a command that quits the app.
  @Test("menu tags round-trip and none of them is the default tag")
  func menuTagsRoundTrip() {
    for command in MenuBarCommand.allCases {
      #expect(command.menuTag != 0)
      #expect(MenuBarCommand.command(forMenuTag: command.menuTag) == command)
    }
    let tags = MenuBarCommand.allCases.map(\.menuTag)
    #expect(Set(tags).count == tags.count)
    #expect(MenuBarCommand.command(forMenuTag: 0) == nil)
  }

  @Test("the rows render in the mockup's order, with Sair last")
  func renderOrderMatchesTheMockup() {
    #expect(MenuBarCommand.allCases == [.openSettings, .openHistory, .quit])
    #expect(
      MenuBarCommand.allCases.map(\.title)
        == ["Abrir Ajustes", "Abrir Histórico", "Sair do Fala"])
  }

  @Test("each command carries the handoff's SF Symbol")
  func symbolsComeFromTheIconMap() {
    #expect(MenuBarCommand.openSettings.symbol == FalaSymbol.settings)
    #expect(MenuBarCommand.openHistory.symbol == FalaSymbol.history)
    #expect(MenuBarCommand.quit.symbol == FalaSymbol.power)
  }
}

@Suite struct MenuBarQuickActionTests {

  /// The review's finding: two of the three rows ship with no handler, and a
  /// dead row must not advertise a key that does nothing.
  @Test("a row with no handler is disabled and advertises no shortcut")
  func disabledRowAdvertisesNothing() {
    let row = MenuBarQuickAction(command: .openSettings, isEnabled: false)
    #expect(!row.isEnabled)
    #expect(row.shortcutHint == nil)
    #expect(row.accessibilityHint == MenuBarStrings.unavailableAction)
    #expect(row.accessibilityHint == "Ainda não disponível.")
  }

  @Test("a row with a handler shows its shortcut and no 'unavailable' hint")
  func enabledRowAdvertisesItsKey() {
    let row = MenuBarQuickAction(command: .quit, isEnabled: true)
    #expect(row.shortcutHint == "⌘ Q")
    #expect(row.accessibilityHint == nil)
  }

  @Test("a command with no shortcut shows no hint even when it is live")
  func historyNeverShowsAHint() {
    #expect(MenuBarQuickAction(command: .openHistory, isEnabled: true).shortcutHint == nil)
  }

  /// Exactly the shipping wiring: only `quit` is resolved, Ajustes (T2.6) and
  /// Histórico (T2.5) have no surface yet.
  @Test("the shipped popover has one live row and two visibly dead ones")
  func shippedWiringIsHonest() {
    let rows = MenuBarQuickAction.all { $0 == .quit }
    #expect(rows.map(\.command) == MenuBarCommand.allCases)
    #expect(rows.map(\.isEnabled) == [false, false, true])
    #expect(rows.compactMap(\.shortcutHint) == ["⌘ Q"])
  }
}

@Suite struct MenuBarRowStyleTests {

  /// A disabled row must LOOK disabled. The view used to paint `text.primary`
  /// on the label unconditionally, which overrode the dimming
  /// `.buttonStyle(.plain)` derives from `isEnabled`.
  @Test("a disabled row is drawn in different colors from a live one")
  func disabledRowIsDimmed() {
    for theme in [Theme.light, Theme.dark] {
      let live = theme.quickActionStyle(isEnabled: true)
      let dead = theme.quickActionStyle(isEnabled: false)
      #expect(live != dead)
      #expect(live.title != dead.title)
      #expect(live.symbol != dead.symbol)
      #expect(dead.title == theme.color.text.tertiary)
      #expect(dead.symbol == theme.color.text.tertiary)
      #expect(live.title == theme.color.text.primary)
      #expect(live.symbol == theme.color.text.secondary)
    }
  }
}

@Suite struct MenuBarSurfaceTests {

  /// HIG: the fallback for a material must be OPAQUE — that is what the setting
  /// asks for. `bg.vibrancy` is the flat stand-in for the material itself and
  /// keeps its alpha, so it is the one token that cannot be this fallback.
  @Test("the Reduce-Transparency fallback is an opaque token, in both appearances")
  func fallbackIsOpaque() {
    for appearance in DesignSystem.Appearance.allCases {
      let palette = DesignSystem.palette(for: appearance)
      #expect(palette.bg.canvas.opacity == 1)
      #expect(Theme(appearance: appearance).reduceTransparencyFill == palette.bg.canvas.color)
      // The token that used to be painted here, pinned so the regression is
      // visible if anyone puts it back.
      #expect(palette.bg.vibrancy.opacity < 1)
    }
  }
}

@Suite struct MenuBarTypeTests {

  /// The mockup overrides the type scale in two spots. Naming the overrides
  /// keeps the raw numbers out of the views AND keeps them tied to the scale.
  @Test("the mockup's weight overrides derive from the type tokens")
  func typeOverridesDeriveFromTheScale() {
    #expect(MenuBarType.brandName.size == DesignSystem.TypeScale.headline.size)
    #expect(MenuBarType.brandName.fontWeight == .bold)
    #expect(MenuBarType.brandName.family == .display)
    #expect(MenuBarType.blockTitle.size == DesignSystem.TypeScale.caption.size)
    #expect(MenuBarType.blockTitle.fontWeight == .semibold)
  }

  @Test("the ⌘ hint is the micro token in the mono family")
  func shortcutHintIsMonospaced() {
    #expect(MenuBarType.shortcutHint.size == DesignSystem.TypeScale.micro.size)
    #expect(MenuBarType.shortcutHint.weight == DesignSystem.TypeScale.micro.weight)
    #expect(MenuBarType.shortcutHint.family == .mono)
  }
}

// MARK: - Banner and model block

@Suite struct MenuBarBlockTests {

  @Test("no pending permission means no banner at all")
  func healthyHidesTheBanner() {
    #expect(PermissionsBanner(missing: []) == nil)
  }

  @Test("the banner reads 'Acessibilidade e Microfone' whatever order it is fed")
  func bannerOrderIsFixed() {
    let banner = PermissionsBanner(missing: [.microphone, .accessibility])
    #expect(banner?.names == "Acessibilidade e Microfone")
    #expect(banner?.message == "Permissões pendentes: Acessibilidade e Microfone")
    let reversed = PermissionsBanner(missing: [.accessibility, .microphone])
    #expect(reversed?.names == banner?.names)
  }

  @Test("a single pending permission is named alone")
  func singlePermission() {
    #expect(PermissionsBanner(missing: [.microphone])?.names == "Microfone")
  }

  @Test("a duplicated permission is not named twice")
  func duplicatesAreCollapsed() {
    let banner = PermissionsBanner(missing: [.microphone, .microphone])
    #expect(banner?.missing.count == 1)
  }

  @Test("the banner deep-links to System Settings and is amber")
  func bannerCarriesItsAffordances() {
    let banner = PermissionsBanner(missing: [.accessibility])
    #expect(banner?.actionTitle == "Conceder")
    #expect(banner?.settingsURL != nil)
    // DESIGN-HANDOFF.md §2/§3: pending permissions are the amber warning state.
    #expect(banner?.stateKind == .warning)
    #expect(banner?.symbol == FalaSymbol.warning)
  }

  @Test("pt-BR enumeration: 'A', 'A e B', 'A, B e C'")
  func listJoining() {
    #expect(PtBRList.join([]).isEmpty)
    #expect(PtBRList.join(["A"]) == "A")
    #expect(PtBRList.join(["A", "B"]) == "A e B")
    #expect(PtBRList.join(["A", "B", "C"]) == "A, B e C")
  }

  @Test("progress is clamped to 0...1 and never divides by zero")
  func progressIsSafe() {
    #expect(ModelDownloadProgress(receivedBytes: 0, totalBytes: 0).fraction == 0)
    #expect(ModelDownloadProgress(receivedBytes: 10, totalBytes: 0).fraction == 0)
    #expect(ModelDownloadProgress(receivedBytes: -5, totalBytes: 100).fraction == 0)
    #expect(ModelDownloadProgress(receivedBytes: 500, totalBytes: 100).fraction == 1)
    #expect(ModelDownloadProgress(receivedBytes: 50, totalBytes: 200).fraction == 0.25)
  }

  @Test("the percentage is rounded, not truncated")
  func percentRounds() {
    #expect(ModelDownloadProgress(receivedBytes: 626, totalBytes: 1000).percent == 63)
    #expect(ModelDownloadProgress(receivedBytes: 624, totalBytes: 1000).percent == 62)
  }

  @Test("an unknown total is indeterminate and shows no fake number")
  func unknownTotalIsIndeterminate() {
    let unknown = ModelDownloadProgress.unknown
    #expect(!unknown.isDeterminate)
    #expect(unknown.detail.isEmpty)
    #expect(ModelBlock.downloading(unknown).title(engine: "Parakeet v3") == "Baixando modelo…")
    #expect(ModelBlock.downloading(unknown).progressFraction == nil)
    #expect(ModelBlock.downloading(unknown).isDownloading)
  }

  @Test("a known total shows the percentage and a 'X de Y' detail")
  func determinateDownloadIsLabelled() {
    let progress = ModelDownloadProgress(receivedBytes: 620_000_000, totalBytes: 1_100_000_000)
    let block = ModelBlock.downloading(progress)
    #expect(block.title(engine: "Parakeet v3") == "Baixando modelo… 56%")
    // The byte formatting follows the machine's locale, so only the shape of the
    // string is pinned here.
    #expect(block.detail.contains(" de "))
    #expect(block.progressFraction != nil)
  }

  @Test("what is on disk decides pronto vs pending — nothing here downloads")
  func blockReadsTheDisk() {
    #expect(ModelBlock.onDisk(makeStatus(present: true)) != .pending)
    #expect(ModelBlock.onDisk(makeStatus(present: false)) == .pending)
    #expect(
      ModelBlock.onDisk(makeStatus(present: true)).title(engine: "Parakeet")
        == "Modelo Parakeet · pronto")
    #expect(ModelBlock.onDisk(makeStatus(present: true)).detail.hasSuffix("local"))
  }

  @Test("only the failed variant offers 'Tentar novamente'")
  func onlyFailureOffersRetry() {
    #expect(ModelBlock.failed.actionTitle == "Tentar novamente")
    #expect(ModelBlock.ready(detail: "1,1 GB").actionTitle == nil)
    #expect(ModelBlock.pending.actionTitle == nil)
    #expect(ModelBlock.downloading(.unknown).actionTitle == nil)
  }

  @Test("each variant maps onto the state vocabulary and the handoff's icon map")
  func variantsUseTheSharedVocabulary() {
    #expect(ModelBlock.ready(detail: "").stateKind == .success)
    #expect(ModelBlock.ready(detail: "").symbol == FalaSymbol.processor)
    #expect(ModelBlock.downloading(.unknown).stateKind == .transcribing)
    #expect(ModelBlock.downloading(.unknown).symbol == FalaSymbol.download)
    #expect(ModelBlock.pending.stateKind == .idle)
    #expect(ModelBlock.failed.stateKind == .error)
    #expect(ModelBlock.failed.symbol == FalaSymbol.error)
  }

  @Test("a model present but unmeasurable shows no empty 'local' suffix")
  func missingSizeLeavesNoDanglingWord() {
    let block = ModelBlock.onDisk(makeStatus(present: true, bytes: nil))
    #expect(block.detail.isEmpty)
  }
}

// MARK: - The last failure

/// Before this, a failed dictation had NO surface in the popover: the status
/// icon collapses `.failure` to idle and the pill is gone after 2.5s. A user
/// looking at their editor when the injection was blocked (US-3) never learned
/// why nothing appeared.
@Suite struct DictationFailureNoticeTests {
  private let now = Date(timeIntervalSince1970: 1_000_000)

  @Test("only a failure produces a notice")
  func onlyFailuresProduceANotice() {
    #expect(DictationFailureNotice(state: .idle, at: now) == nil)
    #expect(DictationFailureNotice(state: .recording, at: now) == nil)
    #expect(DictationFailureNotice(state: .success, at: now) == nil)
    #expect(DictationFailureNotice(state: .transcribing(capturedSeconds: 2), at: now) == nil)
  }

  /// The whole point: the coordinator's pt-BR message reaches the user.
  @Test("the coordinator's message survives verbatim")
  func messageIsPreserved() {
    let blocked = DictationCoordinator.message(for: .secureInputActive)
    let notice = DictationFailureNotice(state: .failure(message: blocked), at: now)
    #expect(notice?.message == "Campo protegido — injeção bloqueada.")
    #expect(notice?.message == blocked)
    #expect(notice?.stateKind == .error)
  }

  @Test("a failure with no message still says something")
  func emptyMessageFallsBackToPortuguese() {
    let empty = DictationFailureNotice(state: .failure(message: ""), at: now)
    #expect(empty?.message == "A ditada falhou.")
    let blank = DictationFailureNotice(state: .failure(message: "   \n"), at: now)
    #expect(blank?.message == DictationFailureNotice.genericMessage)
  }

  /// The mockup draws a secure-field block with the padlock, not the generic
  /// triangle — the same cause map the pill uses, reused rather than retyped.
  @Test("a secure-field block is drawn with the padlock")
  func secureFieldUsesTheLockGlyph() {
    let blocked = DictationCoordinator.message(for: .secureInputActive)
    #expect(
      DictationFailureNotice(state: .failure(message: blocked), at: now)?.symbol
        == FalaSymbol.secureField)
    #expect(
      DictationFailureNotice(state: .failure(message: "A gravação falhou."), at: now)?.symbol
        == FalaSymbol.error)
  }

  @Test("the notice ages in pt-BR and reads as one line to VoiceOver")
  func metaAndAccessibility() {
    let notice = DictationFailureNotice(
      state: .failure(message: "Nada foi capturado."), at: now.addingTimeInterval(-120))
    #expect(notice?.metaLine(relativeTo: now) == "há 2 min")
    #expect(notice?.accessibilityLabel(relativeTo: now) == "Nada foi capturado. · há 2 min")
    #expect(notice?.dismissTitle == "Dispensar")
  }
}

// MARK: - Presenter

@MainActor
@Suite struct MenuBarPresenterTests {

  private func makePresenter(
    granted: Set<Permission> = [.microphone, .accessibility],
    modelPresent: Bool = true,
    recents: any RecentTranscriptionsProviding = StubRecents(),
    enabled: Bool = true,
    engine: TranscriptionEngineChoice = .parakeet
  ) -> MenuBarPresenter {
    MenuBarPresenter(
      dictation: DictationSwitch(store: MockDictationStore(stored: enabled)),
      permissions: MockPermissionChecker(granted: granted),
      modelStatus: { makeStatus(present: modelPresent) },
      engineName: { engine.shortName },
      history: recents,
      clock: { Date(timeIntervalSince1970: 1_000_000) })
  }

  /// Reported as "na tela de destaque aparece Parakeet e vem de Cohere": the
  /// block's name was the constant "Parakeet" while the status under it was
  /// measured in the SELECTED engine's directory. A row whose two halves
  /// describe different engines is worse than either half being wrong — it reads
  /// as the engine switch having silently failed.
  @Test("The model block names the engine actually selected")
  func modelBlockNamesTheSelectedEngine() async {
    let cohere = makePresenter(engine: .cohere)
    await cohere.refresh()
    #expect(cohere.modelTitle.contains("Cohere"))
    #expect(!cohere.modelTitle.contains("Parakeet"))

    let parakeet = makePresenter(engine: .parakeet)
    await parakeet.refresh()
    #expect(parakeet.modelTitle.contains("Parakeet"))
  }

  /// Every state that names a model must follow the selection, not just the
  /// happy one — a failed Cohere download reporting "Falha ao baixar o modelo
  /// Parakeet" would send the user to delete the wrong directory.
  @Test("Pending and failed blocks name the selected engine too")
  func everyNamedStateFollowsTheSelection() async {
    let presenter = makePresenter(modelPresent: false, engine: .cohere)
    await presenter.refresh()
    #expect(presenter.modelTitle.contains("Cohere"))

    presenter.reportModelFailure()
    #expect(presenter.modelTitle.contains("Cohere"))
    #expect(!presenter.modelTitle.contains("Parakeet"))
  }

  @Test("a healthy machine shows no banner")
  func healthyHasNoBanner() async {
    let presenter = makePresenter()
    await presenter.refresh()
    #expect(presenter.permissionsBanner == nil)
    #expect(presenter.isHealthy)
  }

  @Test("a pending permission raises the banner")
  func pendingRaisesTheBanner() async {
    let presenter = makePresenter(granted: [.microphone])
    await presenter.refresh()
    #expect(presenter.permissionsBanner?.missing == [.accessibility])
    #expect(!presenter.isHealthy)
  }

  /// Reopening the popover re-reads the disk. Without the override, that would
  /// silently replace "Tentar novamente" with "baixa no primeiro uso" and strand
  /// the user with no way to retry.
  @Test("refresh does not erase a reported download failure")
  func refreshKeepsTheFailure() async {
    let presenter = makePresenter(modelPresent: false)
    presenter.reportModelFailure()
    await presenter.refresh()
    #expect(presenter.model == .failed)
    #expect(!presenter.isHealthy)
  }

  @Test("clearing the download goes back to reading the disk")
  func clearingRereadsTheDisk() async {
    let presenter = makePresenter(modelPresent: true)
    presenter.reportModelFailure()
    presenter.clearModelDownload()
    #expect(presenter.model != .failed)
    await presenter.refresh()
    #expect(presenter.modelTitle == "Modelo Parakeet · pronto")
  }

  @Test("a reported progress replaces the disk reading while it runs")
  func progressOverridesTheDisk() async {
    let presenter = makePresenter(modelPresent: false)
    presenter.reportModelProgress(ModelDownloadProgress(receivedBytes: 1, totalBytes: 4))
    await presenter.refresh()
    #expect(presenter.model.progressFraction == 0.25)
  }

  @Test("the popover asks history for at most four rows")
  func recentsAreCapped() async {
    let provider = RecordingRecents()
    let presenter = MenuBarPresenter(
      dictation: DictationSwitch(store: MockDictationStore(stored: true)),
      permissions: MockPermissionChecker(granted: []),
      modelStatus: { makeStatus(present: false) },
      engineName: { TranscriptionEngineChoice.parakeet.shortName },
      history: provider,
      recentsLimit: 500)
    await presenter.refresh()
    let asked = await provider.lastLimit
    #expect(asked == MenuBarLayout.maxRecents)
  }

  @Test("recents render in the order the provider vends them")
  func recentsAreRendered() async {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let entries = [
      RecentTranscription(text: "primeira", createdAt: now, destinationApp: "Slack"),
      RecentTranscription(text: "segunda", createdAt: now, destinationApp: "Mail"),
    ]
    let presenter = makePresenter(recents: StubRecents(entries: entries))
    await presenter.refresh()
    #expect(presenter.recents.map(\.text) == ["primeira", "segunda"])
  }

  @Test("the status icon follows the coordinator and the switch")
  func iconFollowsStateAndSwitch() {
    let presenter = makePresenter(enabled: true)
    #expect(presenter.iconVariant == .idle)
    presenter.apply(.recording)
    #expect(presenter.iconVariant == .recording)
    presenter.apply(.idle)
    presenter.dictation.setEnabled(false)
    #expect(presenter.iconVariant == .disabled)
  }

  @Test("observing the coordinator's stream drives the presenter")
  func observeConsumesTheStream() async {
    let presenter = makePresenter()
    let (stream, continuation) = AsyncStream<DictationState>.makeStream()
    let task = presenter.observe(stream)
    continuation.yield(.transcribing(capturedSeconds: 2))
    continuation.finish()
    await task.value
    #expect(presenter.state == .transcribing(capturedSeconds: 2))
  }

  @Test("'now' is re-read on refresh, so ages are right when the popover opens")
  func refreshRereadsTheClock() async {
    let presenter = makePresenter()
    await presenter.refresh()
    #expect(presenter.now == Date(timeIntervalSince1970: 1_000_000))
  }

  /// A limit of 0 used to clamp to 0: history was asked for nothing, so the
  /// popover rendered "Nenhuma ditada ainda." forever with a populated history
  /// right behind it.
  @Test("a zero limit still asks for one row instead of rendering empty forever")
  func zeroLimitIsClampedUp() async {
    let provider = RecordingRecents()
    let presenter = MenuBarPresenter(
      dictation: DictationSwitch(store: MockDictationStore(stored: true)),
      permissions: MockPermissionChecker(granted: []),
      modelStatus: { makeStatus(present: false) },
      engineName: { TranscriptionEngineChoice.parakeet.shortName },
      history: provider,
      recentsLimit: 0)
    await presenter.refresh()
    let asked = await provider.lastLimit
    #expect(asked == MenuBarLayout.minRecents)
    #expect(asked == 1)
  }

  @Test("a negative limit is clamped the same way")
  func negativeLimitIsClampedUp() async {
    let entries = [
      RecentTranscription(text: "primeira", createdAt: .init(), destinationApp: "Slack")
    ]
    let presenter = MenuBarPresenter(
      dictation: DictationSwitch(store: MockDictationStore(stored: true)),
      permissions: MockPermissionChecker(granted: []),
      modelStatus: { makeStatus(present: false) },
      engineName: { TranscriptionEngineChoice.parakeet.shortName },
      history: StubRecents(entries: entries),
      recentsLimit: -10)
    await presenter.refresh()
    #expect(presenter.recents.count == 1)
  }

  // MARK: Last failure

  @Test("a failed dictation is kept, with the coordinator's own pt-BR message")
  func failureIsSurfaced() {
    let presenter = makePresenter()
    #expect(presenter.lastFailure == nil)
    let blocked = DictationCoordinator.message(for: .secureInputActive)
    presenter.apply(.failure(message: blocked))
    #expect(presenter.lastFailure?.message == blocked)
    #expect(presenter.lastFailure?.occurredAt == Date(timeIntervalSince1970: 1_000_000))
  }

  /// The reason it exists at all: the popover is the only surface that outlives
  /// the pill's 2.5s, and reopening it re-reads permissions and the disk.
  @Test("refresh does not erase the last failure")
  func refreshKeepsTheLastFailure() async {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "A gravação falhou."))
    await presenter.refresh()
    #expect(presenter.lastFailure?.message == "A gravação falhou.")
  }

  @Test("the coordinator returning to idle does not erase it")
  func idleDoesNotEraseIt() {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "Nada foi capturado."))
    presenter.apply(.idle)
    #expect(presenter.lastFailure != nil)
  }

  @Test("the next dictation supersedes it")
  func newAttemptClearsIt() {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "Nada foi capturado."))
    presenter.apply(.recording)
    #expect(presenter.lastFailure == nil)
  }

  @Test("a success clears it")
  func successClearsIt() {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "Nada foi capturado."))
    presenter.apply(.success)
    #expect(presenter.lastFailure == nil)
  }

  @Test("a second failure replaces the first")
  func failuresDoNotAccumulate() {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "Nada foi capturado."))
    presenter.apply(.failure(message: "A transcrição falhou."))
    #expect(presenter.lastFailure?.message == "A transcrição falhou.")
  }

  @Test("'Dispensar' clears it and nothing brings it back")
  func dismissDropsIt() async {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "A gravação falhou."))
    presenter.dismissLastFailure()
    #expect(presenter.lastFailure == nil)
    await presenter.refresh()
    #expect(presenter.lastFailure == nil)
  }

  /// The status icon still collapses failure to idle — the popover is the
  /// persistent surface, the menu bar is not.
  @Test("surfacing the failure did not change the status icon's rules")
  func iconStillCollapsesFailure() {
    let presenter = makePresenter()
    presenter.apply(.failure(message: "A gravação falhou."))
    #expect(presenter.iconVariant == .idle)
  }
}

// MARK: - Copy

@Suite struct MenuBarStringsTests {

  /// DESIGN-HANDOFF.md §1 and §4: the privacy line is functional copy and is
  /// visible in every variant of this surface. Pinned character for character
  /// because it is the brand's central claim.
  @Test("the privacy footer is exactly the handoff's line")
  func privacyFooterIsVerbatim() {
    #expect(MenuBarStrings.privacyFooter == "100% no seu Mac · sem telemetria")
  }

  @Test("every menu-bar string is pt-BR and non-empty")
  func stringsArePortuguese() {
    let strings = [
      MenuBarStrings.recentsTitle, MenuBarStrings.recentsEmpty,
      MenuBarStrings.openSettings, MenuBarStrings.openHistory,
      MenuBarStrings.quit, MenuBarStrings.copy, MenuBarStrings.dictationToggleHelp,
    ]
    #expect(strings.allSatisfy { !$0.isEmpty })
    #expect(MenuBarStrings.openSettings == "Abrir Ajustes")
    #expect(MenuBarStrings.openHistory == "Abrir Histórico")
    #expect(MenuBarStrings.openSettingsShortcut == "⌘ ,")
  }

  @Test("the popover is 340pt wide, as the handoff specifies")
  func popoverWidthMatchesTheHandoff() {
    #expect(MenuBarLayout.popoverWidth == 340)
    #expect(MenuBarLayout.maxRecents == 4)
  }
}
