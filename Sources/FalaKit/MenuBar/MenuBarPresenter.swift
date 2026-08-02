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
  /// The download progress track (menubar-popover.dc.html:97).
  public static let progressHeight: CGFloat = 4
  /// The 1px borders the mockup draws around the banner and the model block.
  public static let hairline: CGFloat = 1
  /// "3–4 truncated transcriptions" (handoff §1).
  public static let maxRecents = 4
}

/// Every fixed string in the popover, in one place (pt-BR by project rule).
///
/// The privacy line is functional, not decoration: DESIGN-HANDOFF.md §1 and §4
/// both call it out, and it is the only element that must be visible in every
/// single variant of this surface.
public enum MenuBarStrings {
  public static let brandName = "Fala"
  public static let recentsTitle = "Recentes"
  public static let recentsEmpty = "Nenhuma ditada ainda."
  public static let openSettings = "Abrir Ajustes"
  public static let openSettingsShortcut = "⌘ ,"
  public static let openHistory = "Abrir Histórico"
  public static let quit = "Sair do Fala"
  public static let quitShortcut = "⌘ Q"
  public static let copy = "Copiar"
  public static let privacyFooter = "100% no seu Mac · sem telemetria"
  public static let dictationToggleHelp = "Ativar ou desativar o ditado"
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

  public let dictation: DictationSwitch

  @ObservationIgnored private let permissions: any PermissionChecking
  @ObservationIgnored private let modelStatus: @Sendable () -> ModelStatus
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
    history: any RecentTranscriptionsProviding = NoRecentTranscriptions(),
    clock: @escaping @Sendable () -> Date = { Date() },
    recentsLimit: Int = MenuBarLayout.maxRecents
  ) {
    self.dictation = dictation
    self.permissions = permissions
    self.modelStatus = modelStatus
    self.history = history
    self.clock = clock
    // 3–4 rows per DESIGN-HANDOFF.md §1. Clamped so a caller cannot turn the
    // popover into a full history window — and, more to the point, cannot hold
    // hundreds of transcripts in memory — by passing 500.
    self.recentsLimit = min(max(recentsLimit, 0), MenuBarLayout.maxRecents)
    self.now = clock()
  }

  /// What the status item should draw.
  public var iconVariant: MenuBarIconVariant {
    MenuBarIconVariant.variant(for: state, dictationEnabled: dictation.isEnabled)
  }

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
