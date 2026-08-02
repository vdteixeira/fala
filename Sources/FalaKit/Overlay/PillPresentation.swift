// What the pill overlay shows, as a value (TASKS.md T2.3, SPEC.md FR-16).
//
// This lives in FalaKit rather than next to the panel on purpose: it is the only
// part of the overlay that is pure, and FalaKitTests is the only test target, so
// anything the tests must reach has to be here. `Sources/Fala/UI` keeps exactly
// the parts that need AppKit or SwiftUI and therefore cannot be unit-tested.
//
// Sources: design/mockups/pill-overlay.dc.html (labels, glyphs, which chrome each
// row shows), design/DESIGN-HANDOFF.md §1 (the surface), §2 (the six states), §5
// (the icon map).

import Foundation

// MARK: - Copy

/// Every pt-BR string the overlay can show, in one place, so no view holds a
/// literal. Values are the mockup's, verbatim.
public enum PillStrings {
  /// pill-overlay.dc.html `hotkeyLabel` default: "Segure ⌥ direito para falar".
  public static func restingHint(hotkey: String) -> String {
    "Segure \(hotkey) para falar"
  }

  public static let recording = "Ouvindo…"
  public static let transcribing = "Transcrevendo…"
  public static let success = "Texto inserido"
  /// Shown when the input route is Bluetooth HFP (DESIGN-HANDOFF.md §3).
  public static let audioRouteWarning = "Microfone dos AirPods em baixa qualidade (HFP)"
  /// The "no dispositivo" trust badge next to the spinner.
  public static let onDevice = "no dispositivo"
  /// Last resort. `DictationCoordinator` always supplies a message, so this is
  /// only reachable if a future state carries an empty one.
  public static let genericFailure = "Algo deu errado."
}

// MARK: - Input

/// Everything the overlay needs to decide what to draw.
///
/// `DictationState` alone is not enough: `warning` is not a dictation state but a
/// property of the audio route (DESIGN-HANDOFF.md §2), so it arrives separately.
public struct PillInput: Sendable, Equatable {
  public var state: DictationState
  /// The input route is Bluetooth HFP. Persists a warning pill while true, and
  /// never blocks dictation (DESIGN-HANDOFF.md §3).
  public var audioRouteDegraded: Bool
  /// Only used to render the hint and the keycap.
  public var hotkey: Hotkey

  public init(
    state: DictationState = .idle,
    audioRouteDegraded: Bool = false,
    hotkey: Hotkey = .rightOption
  ) {
    self.state = state
    self.audioRouteDegraded = audioRouteDegraded
    self.hotkey = hotkey
  }

  /// Which of the six states this renders as.
  ///
  /// A degraded route only surfaces while nothing is happening: during a capture
  /// the live state wins, because the HFP warning must not look like it stopped
  /// the dictation ("não bloqueia o ditado", DESIGN-HANDOFF.md §3).
  public var kind: StateKind {
    if audioRouteDegraded, state == .idle { return .warning }
    return state.kind
  }

  /// The pt-BR message of a failure, if this is one. Never contains transcript
  /// text — `DictationCoordinator` guarantees that.
  public var failureMessage: String? {
    guard case .failure(let message) = state else { return nil }
    return message
  }

  /// The same input once the dictation flow has finished and the pill is about to
  /// go away. Used to bring the HFP warning back after a success or an error has
  /// auto-dismissed; without it the warning would be shown once at launch and
  /// then never again, because the coordinator never returns to `.idle`.
  public var atRest: PillInput {
    PillInput(state: .idle, audioRouteDegraded: audioRouteDegraded, hotkey: hotkey)
  }
}

// MARK: - Presentation

/// One fully resolved pill: which glyph, which pt-BR line, and which optional
/// chrome. Deliberately flat — the view switches on nothing.
public struct PillPresentation: Sendable, Equatable {
  public let kind: StateKind
  /// SF Symbol name (DESIGN-HANDOFF.md §5), cause-specific where the mockup is.
  public let symbol: String
  /// The pt-BR line. Always non-empty.
  public let label: String
  /// The six animated bars driven by voice level (functional, §4).
  public let showsWaveform: Bool
  /// The monospaced keycap chip teaching the gesture, or `nil`.
  public let hotkeyHint: String?
  /// The amber "no dispositivo" badge next to the spinner.
  public let showsOnDeviceBadge: Bool
  /// Whether the glyph rotates (`fala-spin`).
  public let spinsIcon: Bool

  public init(_ input: PillInput) {
    let kind = input.kind
    self.kind = kind
    switch kind {
    case .idle:
      symbol = FalaSymbol.idle
      label = PillStrings.restingHint(hotkey: input.hotkey.displayName)
      showsWaveform = false
      hotkeyHint = nil
      showsOnDeviceBadge = false
      spinsIcon = false
    case .recording:
      // `FalaSymbol.idle` is `mic.fill`, and that is deliberate here.
      // DESIGN-HANDOFF.md §2 lists `waveform` as the recording glyph for
      // surfaces that show ONE icon; the pill is not one of those. Its mockup
      // row renders the Material `mic` glyph PLUS a separate animated waveform
      // component, so §5's mic → mic.fill applies and the waveform role is
      // carried by the bars. Using `waveform` here would draw a waveform glyph
      // next to a waveform. DESIGN.md: the mockup wins on visuals.
      symbol = FalaSymbol.idle
      label = PillStrings.recording
      showsWaveform = true
      hotkeyHint = input.hotkey.displayName
      showsOnDeviceBadge = false
      spinsIcon = false
    case .transcribing:
      symbol = FalaSymbol.transcribing
      label = PillStrings.transcribing
      showsWaveform = false
      hotkeyHint = nil
      showsOnDeviceBadge = true
      spinsIcon = true
    case .success:
      symbol = FalaSymbol.success
      label = PillStrings.success
      showsWaveform = false
      hotkeyHint = nil
      showsOnDeviceBadge = false
      spinsIcon = false
    case .error:
      let message = input.failureMessage ?? PillStrings.genericFailure
      symbol =
        Self.isSecureFieldFailure(message) ? FalaSymbol.secureField : FalaSymbol.error
      label = message.isEmpty ? PillStrings.genericFailure : message
      showsWaveform = false
      hotkeyHint = nil
      showsOnDeviceBadge = false
      spinsIcon = false
    case .warning:
      // The only warning v1 can produce is the HFP route, so the cause glyph
      // from §2 (`airpods`) is always the right one here.
      symbol = FalaSymbol.headphones
      label = PillStrings.audioRouteWarning
      showsWaveform = false
      hotkeyHint = nil
      showsOnDeviceBadge = false
      spinsIcon = false
    }
  }

  /// Whether a failure was the secure-field block, which the mockup draws with
  /// `lock.fill` instead of the generic triangle.
  ///
  /// `DictationState.failure` carries only a pt-BR message, so the cause has to
  /// be recovered from it. This compares against the coordinator's OWN canonical
  /// string rather than a literal retyped here, which is why it is confined to
  /// FalaKit. It is still a string comparison: the durable fix is a typed cause
  /// on `DictationState.failure`, which is outside this task's file scope.
  static func isSecureFieldFailure(_ message: String) -> Bool {
    message == DictationCoordinator.message(for: .secureInputActive)
  }
}

// MARK: - Content

/// The three things the overlay window can be showing. `PillOverlayController`
/// owns the timing; this enum owns the vocabulary.
public enum PillOverlayContent: Sendable, Equatable {
  /// Nothing at all — the panel is ordered out.
  case hidden
  /// The 28×5 sliver at 35% opacity (DESIGN-HANDOFF.md §1, "oculta").
  case collapsed
  case pill(PillPresentation)

  public var isVisible: Bool {
    if case .hidden = self { return false }
    return true
  }

  /// What to show the moment `input` changes, before any timer has run.
  public static func initial(for input: PillInput) -> PillOverlayContent {
    input.kind == .idle ? .collapsed : .pill(PillPresentation(input))
  }

  /// What to show once the current content has served its time: nothing, unless
  /// the audio route is still degraded, in which case the warning comes back and
  /// stays (DESIGN-HANDOFF.md §1: "warning persists while HFP route is active").
  public static func resting(for input: PillInput) -> PillOverlayContent {
    input.audioRouteDegraded ? .pill(PillPresentation(input.atRest)) : .hidden
  }

  /// How visually "present" this content is. Only used to pick a motion role.
  private var rank: Int {
    switch self {
    case .hidden: return 0
    case .collapsed: return 1
    case .pill: return 2
    }
  }

  /// Which of DESIGN-HANDOFF.md §6's motions a content change is: growing more
  /// present is an entrance, shrinking is a dismissal, anything else is a swap.
  public static func motion(from old: PillOverlayContent, to new: PillOverlayContent)
    -> PillMotionRole
  {
    if old.rank < new.rank { return .enter }
    if old.rank > new.rank { return .exit }
    return .change
  }
}

/// Which timing a content change gets (DESIGN-HANDOFF.md §6).
public enum PillMotionRole: Sendable, Equatable {
  /// `fala-appear` — 320ms spring.
  case enter
  /// `fala-dismiss` — 200ms standard.
  case exit
  /// An icon/label swap inside a pill that is already on screen — 120ms.
  case change
}
