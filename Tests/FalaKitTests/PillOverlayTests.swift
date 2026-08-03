import CoreGraphics
import Foundation
import Testing

@testable import FalaKit

/// The pill overlay's pure logic (TASKS.md T2.3, SPEC.md FR-16).
///
/// The panel itself needs a screen, a window server and a running app, so it is
/// not unit-testable. Everything it DECIDES is, and that is what lives here: what
/// each state shows, when it goes away, and where the window lands. The timing
/// table is the part most likely to rot silently — nobody notices a success pill
/// that lingers half a second too long, and everybody notices a warning that
/// vanishes while their AirPods are still degrading the audio.
@Suite struct PillOverlayTests {

  // MARK: - Auto-dismiss (DESIGN-HANDOFF.md §1)

  @Test("success leaves after 1.2s and error after 2.5s")
  func timedStatesMatchTheHandoff() {
    let policy = PillDismissPolicy.standard
    #expect(policy.dismissal(for: .success) == .after(1.2))
    #expect(policy.dismissal(for: .error) == .after(2.5))
  }

  @Test("warning NEVER auto-dismisses — it is a condition, not an event")
  func warningPersists() {
    let policy = PillDismissPolicy.standard
    #expect(policy.dismissal(for: .warning) == .persists)
    #expect(policy.dismissal(for: .warning).delay == nil)
    #expect(policy.dismissal(for: .warning).isAutomatic == false)

    // And it survives the route being degraded across a whole dictation: the
    // pill that comes back at rest is the warning again, and it also persists.
    let input = PillInput(state: .success, audioRouteDegraded: true)
    let resting = PillOverlayContent.resting(for: input)
    #expect(resting == .pill(PillPresentation(input.atRest)))
    #expect(policy.dismissal(for: resting) == .persists)
  }

  @Test("the live states persist — a timer must never cut a dictation short")
  func liveStatesPersist() {
    let policy = PillDismissPolicy.standard
    #expect(policy.dismissal(for: .recording) == .persists)
    #expect(policy.dismissal(for: .transcribing) == .persists)
  }

  @Test("the resting sliver hides after ~2s of inactivity")
  func idleHides() {
    let policy = PillDismissPolicy.standard
    #expect(policy.dismissal(for: .idle) == .after(2.0))
    #expect(policy.dismissal(for: .collapsed) == .after(2.0))
    // Nothing on screen: nothing to schedule.
    #expect(policy.dismissal(for: .hidden) == .persists)
  }

  @Test("the delays are design tokens, not literals, and do not vary by appearance")
  func delaysComeFromTheTheme() {
    #expect(PillDismissPolicy(pill: Theme.light.pill) == PillDismissPolicy(pill: Theme.dark.pill))
    #expect(PillDismissPolicy(pill: Theme.dark.pill) == .standard)
    #expect(PillDismissPolicy.standard.successDelay == Theme.light.pill.successDismissDelay)
    #expect(PillDismissPolicy.standard.errorDelay == Theme.light.pill.errorDismissDelay)
    #expect(PillDismissPolicy.standard.idleHideDelay == Theme.light.pill.idleHideDelay)
  }

  @Test("every one of the six states has a decision")
  func everyStateHasADismissal() {
    let policy = PillDismissPolicy.standard
    for kind in StateKind.allCases {
      let dismissal = policy.dismissal(for: kind)
      if let delay = dismissal.delay {
        #expect(delay > 0, "\(kind) would dismiss instantly")
      }
    }
  }

  // MARK: - What each state shows (pill-overlay.dc.html)

  @Test("the resting pill teaches the gesture with the real hotkey name")
  func idleShowsTheHotkey() {
    let pill = PillPresentation(PillInput(state: .idle, hotkey: .rightOption))
    #expect(pill.kind == .idle)
    #expect(pill.symbol == "mic.fill")
    #expect(pill.label == "Segure ⌥ direito para falar")
    #expect(pill.label.contains(Hotkey.rightOption.displayName))
    #expect(pill.showsWaveform == false)
    #expect(pill.spinsIcon == false)
  }

  @Test("recording shows the waveform and the keycap, and is rose — never the error red")
  func recordingShowsTheWaveform() {
    let pill = PillPresentation(PillInput(state: .recording))
    #expect(pill.kind == .recording)
    #expect(pill.label == "Ouvindo…")
    #expect(pill.showsWaveform)
    #expect(pill.hotkeyHint == Hotkey.rightOption.displayName)
    #expect(pill.showsOnDeviceBadge == false)
    // The glyph is mic.fill, not `waveform`: the animated bars carry the
    // waveform role in this surface (see PillPresentation.init).
    #expect(pill.symbol == "mic.fill")
    #expect(pill.symbol != FalaSymbol.recording)

    let style = Theme.dark.style(for: pill.kind)
    #expect(style.tint == Theme.dark.color.state.recording)
    #expect(style.tint != Theme.dark.color.state.error)
  }

  @Test("transcribing spins, wears the on-device badge, and leaks no duration")
  func transcribingShowsTheBadge() {
    let pill = PillPresentation(PillInput(state: .transcribing(capturedSeconds: 4.2)))
    #expect(pill.kind == .transcribing)
    #expect(pill.symbol == "arrow.triangle.2.circlepath")
    #expect(pill.spinsIcon)
    #expect(pill.showsOnDeviceBadge)
    // The captured-seconds payload is diagnostic, not user-facing: it must not
    // end up on a HUD floating over somebody else's screen share.
    #expect(pill.label == "Transcrevendo…")
    #expect(pill.label.contains("4") == false)
  }

  @Test("success is the checkmark and nothing else")
  func successIsMinimal() {
    let pill = PillPresentation(PillInput(state: .success))
    #expect(pill.symbol == "checkmark.circle.fill")
    #expect(pill.label == "Texto inserido")
    #expect(pill.showsWaveform == false)
    #expect(pill.hotkeyHint == nil)
    #expect(pill.showsOnDeviceBadge == false)
  }

  @Test("a secure-field block gets the lock glyph; any other failure gets the triangle")
  func errorGlyphFollowsTheCause() {
    // The coordinator's own string, not a literal retyped here — matching a
    // hand-copied pt-BR message is exactly the bug this indirection prevents.
    let secure = DictationCoordinator.message(for: .secureInputActive)
    let blocked = PillPresentation(PillInput(state: .failure(message: secure)))
    #expect(blocked.kind == .error)
    #expect(blocked.symbol == "lock.fill")
    #expect(blocked.label == secure)

    let mic = DictationCoordinator.message(for: .accessibilityDenied)
    let other = PillPresentation(PillInput(state: .failure(message: mic)))
    #expect(other.symbol == "exclamationmark.triangle.fill")
    #expect(other.label == mic)
    #expect(other.symbol != blocked.symbol)
  }

  @Test("the pill shows the failure message verbatim and invents no copy of its own")
  func failureMessagePassesThrough() {
    let message = "A transcrição falhou."
    let pill = PillPresentation(PillInput(state: .failure(message: message)))
    #expect(pill.label == message)

    // Defensive: an empty message would render an empty pill.
    let empty = PillPresentation(PillInput(state: .failure(message: "")))
    #expect(empty.label == PillStrings.genericFailure)
  }

  @Test("a degraded audio route raises the warning only while nothing is being dictated")
  func warningYieldsToLiveStates() {
    let resting = PillInput(state: .idle, audioRouteDegraded: true)
    #expect(resting.kind == .warning)
    let warning = PillPresentation(resting)
    #expect(warning.symbol == "airpods")
    #expect(warning.label == "Microfone dos AirPods em baixa qualidade (HFP)")

    // "não bloqueia o ditado" (DESIGN-HANDOFF.md §3): the live state wins, so the
    // warning never looks like it stopped the capture.
    #expect(PillInput(state: .recording, audioRouteDegraded: true).kind == .recording)
    #expect(
      PillInput(state: .transcribing(capturedSeconds: 1), audioRouteDegraded: true).kind
        == .transcribing)
    #expect(PillInput(state: .success, audioRouteDegraded: true).kind == .success)
  }

  @Test("every state renders a non-empty pt-BR line — colour alone never carries meaning")
  func everyStateIsLegibleAsText() {
    let inputs: [PillInput] = [
      PillInput(state: .idle),
      PillInput(state: .recording),
      PillInput(state: .transcribing(capturedSeconds: 1)),
      PillInput(state: .success),
      PillInput(state: .failure(message: "Nada para inserir.")),
      PillInput(state: .idle, audioRouteDegraded: true),
    ]
    var kinds: Set<StateKind> = []
    for input in inputs {
      let pill = PillPresentation(input)
      kinds.insert(pill.kind)
      #expect(!pill.label.isEmpty, "\(pill.kind) has no label")
      #expect(!pill.symbol.isEmpty, "\(pill.kind) has no symbol")
    }
    #expect(kinds == Set(StateKind.allCases), "a state is unreachable from the overlay")
  }

  // MARK: - Content and motion

  @Test("idle collapses to the sliver; everything else is a full pill")
  func initialContent() {
    #expect(PillOverlayContent.initial(for: PillInput(state: .idle)) == .collapsed)

    let recording = PillInput(state: .recording)
    #expect(PillOverlayContent.initial(for: recording) == .pill(PillPresentation(recording)))

    // A degraded route while idle is a real pill, not a sliver.
    let degraded = PillInput(state: .idle, audioRouteDegraded: true)
    #expect(PillOverlayContent.initial(for: degraded) == .pill(PillPresentation(degraded)))
  }

  @Test("after dismissing, a healthy route shows nothing at all")
  func restingContent() {
    #expect(PillOverlayContent.resting(for: PillInput(state: .success)) == .hidden)
    #expect(PillOverlayContent.resting(for: PillInput(state: .idle)) == .hidden)
    #expect(PillOverlayContent.hidden.isVisible == false)
    #expect(PillOverlayContent.collapsed.isVisible)
  }

  @Test("becoming more present is an entrance, less present a dismissal")
  func motionRoles() {
    let pill = PillOverlayContent.pill(PillPresentation(PillInput(state: .recording)))
    let other = PillOverlayContent.pill(PillPresentation(PillInput(state: .success)))

    #expect(PillOverlayContent.motion(from: .hidden, to: pill) == .enter)
    #expect(PillOverlayContent.motion(from: .hidden, to: .collapsed) == .enter)
    #expect(PillOverlayContent.motion(from: .collapsed, to: pill) == .enter)
    #expect(PillOverlayContent.motion(from: pill, to: .hidden) == .exit)
    #expect(PillOverlayContent.motion(from: .collapsed, to: .hidden) == .exit)
    // A state swap inside a pill that is already on screen is neither.
    #expect(PillOverlayContent.motion(from: pill, to: other) == .change)
  }

  // MARK: - Placement (multiple displays)

  @Test("the band is centred on the active screen and sits on the bottom of its visible frame")
  func panelIsBottomCentred() {
    let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    let frame = PillOverlayGeometry.standard.panelFrame(in: visible)

    #expect(frame.midX == visible.midX)
    #expect(frame.minY == visible.minY)
    #expect(visible.contains(frame))
    #expect(frame.width > 0 && frame.height > 0)
  }

  @Test("a display left of and below the main one places the band inside ITS visible frame")
  func secondaryDisplayWithNegativeOrigin() {
    // AppKit screen coordinates are global: a display to the left of the main one
    // has a negative origin. Centring on `width / 2` instead of on `midX` would
    // silently park the pill on the wrong monitor.
    let visible = CGRect(x: -2560, y: -420, width: 2560, height: 1400)
    let frame = PillOverlayGeometry.standard.panelFrame(in: visible)

    #expect(frame.midX == visible.midX)
    #expect(frame.minY == visible.minY)
    #expect(frame.minX < 0)
    #expect(visible.contains(frame))
  }

  @Test("the band never spills off a narrow or a short screen")
  func clampsToSmallScreens() {
    let geometry = PillOverlayGeometry.standard

    let narrow = CGRect(x: 0, y: 0, width: 200, height: 600)
    let narrowFrame = geometry.panelFrame(in: narrow)
    #expect(narrowFrame.width <= narrow.width)
    #expect(narrow.contains(narrowFrame))

    let short = CGRect(x: 0, y: 0, width: 1440, height: 80)
    let shortFrame = geometry.panelFrame(in: short)
    #expect(shortFrame.height == short.height)
    #expect(short.contains(shortFrame))
  }

  @Test("a screen that reports nothing usable yields an empty frame instead of a NaN one")
  func degenerateScreensAreSurvivable() {
    let geometry = PillOverlayGeometry.standard
    // Reachable while displays are being re-arranged, or on a headless machine.
    #expect(geometry.panelFrame(in: .zero) == .zero)
    #expect(geometry.panelFrame(in: CGRect(x: 10, y: 10, width: 0, height: 500)) == .zero)
    let notANumber = CGFloat.nan
    #expect(geometry.panelFrame(in: CGRect(x: 0, y: 0, width: notANumber, height: 900)) == .zero)
    #expect(geometry.panelFrame(in: CGRect(x: 0, y: 0, width: 1440, height: notANumber)) == .zero)

    let frame = geometry.panelFrame(in: CGRect(x: 0, y: 0, width: 1440, height: 900))
    #expect(frame.origin.x.isFinite && frame.width.isFinite)
  }

  @Test("the band leaves room for a wrapped pill, its shadow and its entrance")
  func bandIsTallEnough() {
    let geometry = PillOverlayGeometry.standard
    let space = Theme.dark.space
    let pill = Theme.dark.pill
    // Two wrapped caption lines + padding + the pop shadow's reach + the 320ms
    // entrance travel + the lift off the bottom of the screen.
    let needed =
      Theme.dark.type.caption.lineHeight * 2 + space.xs * 2
      + (pill.shadow.radius + pill.shadow.y) + PillMetrics.appearOffset + space.xxxl
    #expect(geometry.bandHeight >= needed)
  }

  // MARK: - Sub-token metrics (pill-overlay.dc.html)

  @Test("every waveform bar has a phase, and each starts within one cycle")
  func waveformStaggerIsComplete() {
    #expect(PillMetrics.waveformPhaseOffsets.count == PillMetrics.waveformBarCount)
    let cycle = Theme.dark.motion.waveCycle.seconds
    for offset in PillMetrics.waveformPhaseOffsets {
      #expect(offset >= 0 && offset < cycle, "phase \(offset) falls outside the 900ms cycle")
    }
    // All six differ, or the "wave" is six bars moving as one block.
    #expect(Set(PillMetrics.waveformPhaseOffsets).count == PillMetrics.waveformBarCount)
  }

  @Test("the reduced waveform is a legible height, not a collapsed one")
  func reducedWaveformStaysVisible() {
    #expect(PillMetrics.waveformReducedScale > PillMetrics.waveformMinScale)
    #expect(PillMetrics.waveformReducedScale <= 1)
  }

  /// The pill's keycap is the instruction for HOW to dictate. It was fixed at
  /// construction, so after rebinding the hotkey the overlay kept telling the
  /// user to press a key that no longer did anything — reported from real use.
  @Test("The resting hint follows the bound hotkey")
  func restingHintFollowsTheHotkey() {
    for hotkey in Hotkey.allCases {
      // `.recording` is the state that carries the keycap — and the one the
      // user was looking at when they reported the stale label.
      let input = PillInput(state: .recording, audioRouteDegraded: false, hotkey: hotkey)
      let content = PillOverlayContent.initial(for: input)
      guard case .pill(let presentation) = content else {
        Issue.record("expected a pill while recording")
        continue
      }
      #expect(presentation.hotkeyHint?.contains(hotkey.displayName) == true)
    }
  }
}
