import CoreGraphics
import Foundation
import Observation

/// The few dimensions this surface has that tokens.json does not cover.
///
/// They are sizes of the surface itself, not design tokens, and they come from
/// DESIGN-HANDOFF.md §1 and menubar-popover.dc.html. Naming them once here keeps
/// them out of the views, where DESIGN.md forbids raw numbers.
public enum MenuBarLayout {
  /// "NSPopover, 340pt wide" (handoff §1).
  public static let popoverWidth: CGFloat = 340
  /// The header logo lockup (menubar-popover.dc.html:57).
  public static let logoSize: CGFloat = 26
  /// The 1px strokes the mockup draws around the banner and the model block, and
  /// the 1px rule between the recents and the quick actions. There is no
  /// stroke-width token — `tokens.json` has no `--border-width` — so this is the
  /// one place it is named. Everything else that looked like a constant here was
  /// a token in disguise and has been deleted (the progress track is
  /// `space.xxs`).
  public static let hairline: CGFloat = 1
  /// "3–4 truncated transcriptions" (handoff §1).
  public static let maxRecents = 4
  /// The popover must ask for at least one row. Clamping the caller's value to 0
  /// used to render the empty state forever with a populated history behind it.
  public static let minRecents = 1
}

/// Every fixed string in the popover, in one place (pt-BR by project rule).
///
/// The privacy line is functional, not decoration: DESIGN-HANDOFF.md §1 and §4
/// both call it out, and it is the only element that must be visible in every
/// single variant of this surface.
public enum MenuBarStrings {
  /// THE single place the product's name lives (DESIGN-HANDOFF.md §7: "swap via a
  /// single brand-name constant"). Every user-facing string interpolates this.
  ///
  /// Two things deliberately do NOT follow it: the Application Support directory
  /// (`~/Library/Application Support/Fala`) and the window frame autosave names.
  /// Both address the user's existing data and window positions, and a rename
  /// that moved them would orphan dictionaries, history and layout in
  /// directories nothing looks at any more.
  public static let brandName = "Fala"
  public static let recentsTitle = "Recentes"
  public static let recentsEmpty = "Nenhuma ditada ainda."
  public static let openSettings = "Abrir Ajustes"
  public static let openHistory = "Abrir Histórico"
  public static let quit = "Sair do \(brandName)"
  public static let copy = "Copiar"
  public static let privacyFooter = "100% no seu Mac · sem telemetria"
  public static let dictationToggleHelp = "Ativar ou desativar o ditado"
  /// Said to VoiceOver on a row whose surface does not exist yet; the dimming
  /// alone is invisible to it.
  public static let unavailableAction = "Ainda não disponível."
  /// Clears the last-failure notice.
  public static let dismiss = "Dispensar"

  // The two shortcut hints are DERIVED from the commands that bind them, so the
  // popover cannot print a key the main menu does not carry.
  public static var openSettingsShortcut: String {
    MenuBarCommand.openSettings.shortcut?.display ?? ""
  }
  public static var quitShortcut: String {
    MenuBarCommand.quit.shortcut?.display ?? ""
  }
}

/// Everything the popover renders, assembled from protocol-injected sources.
///
/// This is where the menu bar's logic lives so that it is testable: the SwiftUI
/// view and the `NSStatusItem` in `Sources/Fala/UI` hold no decisions, they only
/// draw what this publishes. Nothing here touches AppKit.
@MainActor
@Observable
public final class MenuBarPresenter {
  /// Mirrors `DictationCoordinator`. The popover shows it; the status icon is
  /// derived from it.
  public private(set) var state: DictationState = .idle
  /// `nil` hides the banner entirely (handoff §3).
  public private(set) var permissionsBanner: PermissionsBanner?
  public private(set) var model: ModelBlock = .pending
  public private(set) var recents: [RecentTranscription] = []
  /// Recomputed on every refresh so "há 2 min" is right when the popover opens
  /// rather than when the entry was created.
  public private(set) var now: Date = .init()

  /// The last dictation that failed, or `nil`.
  ///
  /// DELIBERATE (Phase 2 review): the popover is the only PERSISTENT surface the
  /// app has. The pill states the failure for 2.5 s and the status icon collapses
  /// `.failure` to idle, so a user who was looking at the target app while the
  /// injection was blocked had no way to find out what happened. Keeping the
  /// coordinator's pt-BR message here means it is never silently discarded.
  ///
  /// PRIVACY: the notice holds the message and a timestamp — nothing else.
  /// `DictationState.failure` carries no transcript text, and nothing here is
  /// logged or written to disk.
  public private(set) var lastFailure: DictationFailureNotice?

  public let dictation: DictationSwitch

  @ObservationIgnored private let permissions: any PermissionChecking
  @ObservationIgnored private let modelStatus: @Sendable () -> ModelStatus
  @ObservationIgnored private let engineName: @Sendable () -> String
  @ObservationIgnored private let history: any RecentTranscriptionsProviding
  @ObservationIgnored private let clock: @Sendable () -> Date
  @ObservationIgnored private let recentsLimit: Int

  /// A download in progress or a failed one. Kept apart from `model` because
  /// `refresh()` re-reads the disk, and the disk cannot tell the difference
  /// between "not downloaded yet" and "the download just failed" — without this,
  /// opening the popover would erase the "Tentar novamente" the user needs.
  @ObservationIgnored private var downloadOverride: ModelBlock?

  public init(
    dictation: DictationSwitch,
    permissions: any PermissionChecking = SystemPermissionChecker(),
    modelStatus: @escaping @Sendable () -> ModelStatus = { ModelStatus.current() },
    /// NO DEFAULT, deliberately. With one, removing the wiring in
    /// `MenuBarApp` still compiled and every test still passed — the tests
    /// inject their own name — so the popover would silently go back to saying
    /// "Parakeet" over Cohere's status. The compiler is the only thing that
    /// catches that.
    engineName: @escaping @Sendable () -> String,
    history: any RecentTranscriptionsProviding = NoRecentTranscriptions(),
    clock: @escaping @Sendable () -> Date = { Date() },
    recentsLimit: Int = MenuBarLayout.maxRecents
  ) {
    self.dictation = dictation
    self.permissions = permissions
    self.modelStatus = modelStatus
    self.engineName = engineName
    self.history = history
    self.clock = clock
    // 3–4 rows per DESIGN-HANDOFF.md §1. Clamped so a caller cannot turn the
    // popover into a full history window — and, more to the point, cannot hold
    // hundreds of transcripts in memory — by passing 500.
    //
    // The FLOOR is 1, not 0 (Phase 2 review). Clamping to 0 asked history for
    // zero rows and then rendered "Nenhuma ditada ainda." forever, with a
    // populated history sitting right behind it.
    self.recentsLimit = min(
      max(recentsLimit, MenuBarLayout.minRecents), MenuBarLayout.maxRecents)
    self.now = clock()
  }

  /// What the status item should draw.
  public var iconVariant: MenuBarIconVariant {
    MenuBarIconVariant.variant(for: state, dictationEnabled: dictation.isEnabled)
  }

  /// Headline for the model block, naming the SELECTED engine.
  ///
  /// Read through the same closure `refresh()` uses, so the name and the status
  /// under it always describe the same engine.
  public var modelTitle: String { model.title(engine: engineName()) }

  /// Whether anything is blocking dictation right now — the popover's one
  /// summary signal.
  public var isHealthy: Bool {
    permissionsBanner == nil && model != .failed
  }

  // MARK: Inputs

  /// Re-reads everything that can have changed while the popover was closed:
  /// permissions (the user may have granted them in System Settings), the model
  /// on disk, and the recents list.
  public func refresh() async {
    now = clock()
    permissionsBanner = PermissionsBanner(missing: permissions.missingPermissions)
    model = downloadOverride ?? ModelBlock.onDisk(modelStatus())
    recents = await history.recent(limit: recentsLimit)
  }

  public func apply(_ state: DictationState) {
    self.state = state
    switch state {
    case .failure:
      lastFailure = DictationFailureNotice(state: state, at: clock())
    case .recording, .success:
      // A new attempt supersedes the last outcome: the moment the microphone
      // opens again, the previous failure is history. `.idle` and
      // `.transcribing` deliberately do NOT clear it — the coordinator returns
      // to idle right after a failure, and clearing there would erase the
      // notice before the popover could ever show it.
      lastFailure = nil
    case .idle, .transcribing:
      break
    }
  }

  /// "Dispensar" on the failure notice.
  public func dismissLastFailure() {
    lastFailure = nil
  }

  /// Consumes `DictationCoordinator.states()`. Returns the task so the caller can
  /// cancel it; the stream ends on its own when the coordinator goes away.
  @discardableResult
  public func observe(_ states: AsyncStream<DictationState>) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      for await state in states {
        self?.apply(state)
      }
    }
  }

  public func reportModelProgress(_ progress: ModelDownloadProgress) {
    downloadOverride = .downloading(progress)
    model = .downloading(progress)
  }

  /// The model is on disk and is being loaded into memory. Kept apart from
  /// `reportModelProgress` because it must not say "baixando": selecting an
  /// engine you already have showed a download bar for as long as the load took,
  /// which for Cohere is 97 s.
  public func reportModelLoading() {
    downloadOverride = .loading
    model = .loading
  }

  public func reportModelFailure() {
    downloadOverride = .failed
    model = .failed
  }

  /// Clears a failure or a finished download and re-reads the disk.
  public func clearModelDownload() {
    downloadOverride = nil
    model = ModelBlock.onDisk(modelStatus())
  }
}
