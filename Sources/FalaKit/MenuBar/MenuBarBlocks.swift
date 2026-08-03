import Foundation

// The two conditional blocks of the popover (DESIGN-HANDOFF.md §1): the
// permissions banner, which exists only while something is pending, and the model
// status block, which has one appearance per model condition.
//
// Both are pure values. They carry the pt-BR copy and the `StateKind` the view
// should tint with — never a color, so the view still resolves everything through
// `theme.style(for:)`.

// MARK: - Permissions banner

/// The amber banner, shown ONLY when a permission is pending (handoff §3:
/// "Healthy state hides the banner entirely").
///
/// Failable on purpose: "no banner" is the absence of this value, not a value
/// with an empty list. A view cannot then render an empty banner by mistake.
public struct PermissionsBanner: Sendable, Equatable {
  /// In the order the mockup writes them, deduplicated.
  public let missing: [Permission]

  public init?(missing: [Permission]) {
    // The mockup reads "Acessibilidade e Microfone"; `Permission.allCases` is in
    // the opposite order. Fixing the order here keeps the copy stable no matter
    // what order the checker reports.
    let order: [Permission] = [.accessibility, .microphone]
    let pending = order.filter(missing.contains)
    guard !pending.isEmpty else { return nil }
    self.missing = pending
  }

  /// "Permissões pendentes: " — kept apart from `names` so the view can bold the
  /// names exactly as the mockup's `<strong>` does.
  public var prefix: String { "Permissões pendentes: " }

  /// "Acessibilidade e Microfone".
  public var names: String {
    PtBRList.join(missing.map(\.displayName))
  }

  public var message: String { prefix + names }

  /// Deep-links to System Settings. `Conceder` opens the first pending pane; the
  /// banner stays until every one of them is granted.
  public var actionTitle: String { "Conceder" }

  public var settingsURL: URL? { missing.first?.settingsURL }

  /// Amber, per the mockup (`--color-state-warning`).
  public var stateKind: StateKind { .warning }

  public var symbol: String { FalaSymbol.warning }
}

/// pt-BR enumeration: "A", "A e B", "A, B e C".
public enum PtBRList {
  public static func join(_ items: [String]) -> String {
    guard let last = items.last else { return "" }
    guard items.count > 1 else { return last }
    return items.dropLast().joined(separator: ", ") + " e " + last
  }
}

// MARK: - Last failure

/// The red notice the popover shows after a dictation failed.
///
/// WHY THIS EXISTS (Phase 2 review). `MenuBarIconVariant` collapses `.failure`
/// to idle on purpose — the menu bar has no dismissal timer — and the pill is
/// gone 2.5 s later. Without this the pt-BR message `DictationCoordinator`
/// produced for US-3 (a blocked injection into a secure field) reached the user
/// only if they happened to be looking at the pill. The popover is the app's one
/// persistent surface, so the last failure lives here until it is superseded or
/// dismissed.
///
/// PRIVACY (CLAUDE.md, NFR-1): `message` is the coordinator's own pt-BR string.
/// It never contains transcript text, and this value is in-memory only — nothing
/// writes it to disk, to os_log, or to stdout.
public struct DictationFailureNotice: Sendable, Equatable {
  /// The coordinator's message, verbatim.
  public let message: String
  public let occurredAt: Date

  /// Fails for every state that is not a failure, so the popover cannot render
  /// an empty notice by mistake — same rule as `PermissionsBanner`.
  public init?(state: DictationState, at date: Date) {
    guard case .failure(let message) = state else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    self.message = trimmed.isEmpty ? Self.genericMessage : trimmed
    self.occurredAt = date
  }

  /// Used when a failure arrives with no message at all. An empty red banner
  /// would tell the user less than nothing.
  public static let genericMessage = "A ditada falhou."

  /// Firm red, the same `error` state the pill uses for this (handoff §2).
  public var stateKind: StateKind { .error }

  /// `lock.fill` when the cause was a secure field, the generic triangle
  /// otherwise — the cause map the pill already owns, reused rather than
  /// re-derived.
  public var symbol: String {
    PillPresentation.isSecureFieldFailure(message)
      ? FalaSymbol.secureField : FalaSymbol.error
  }

  public var dismissTitle: String { MenuBarStrings.dismiss }

  /// "há 2 min" — the same pt-BR ages the recents rows use.
  public func metaLine(relativeTo now: Date) -> String {
    RelativeTimePtBR.describe(now.timeIntervalSince(occurredAt))
  }

  /// One line for VoiceOver, which cannot see the icon or the layout.
  public func accessibilityLabel(relativeTo now: Date) -> String {
    "\(message) · \(metaLine(relativeTo: now))"
  }
}

// MARK: - Model status block

/// Download progress, as a value so the percentage arithmetic is testable.
public struct ModelDownloadProgress: Sendable, Equatable {

  /// What the two numbers count.
  ///
  /// FluidAudio reports FILES for the Cohere path (measured: `fractionCompleted`
  /// is always 0.000 there, and the count sits at 1/21 for minutes while the
  /// several-hundred-MB encoder transfers). Rendering that as bytes produced
  /// "1 byte de 21 bytes"; rendering it as a percentage produced a bar frozen at
  /// 5%, which reads as broken. Naming the unit lets the UI say "arquivo 1 de
  /// 21", which reads as working on something big.
  public enum Unit: Sendable, Equatable {
    case bytes
    case files
  }

  public let receivedBytes: Int64
  public let totalBytes: Int64
  public let unit: Unit

  public init(receivedBytes: Int64, totalBytes: Int64, unit: Unit = .bytes) {
    self.receivedBytes = receivedBytes
    self.totalBytes = totalBytes
    self.unit = unit
  }

  /// 0...1. Never NaN and never above 1: the progress bar's width is bound to
  /// this, and an unclamped value would draw outside its track (or crash the
  /// layout on a division by zero before the total size is known).
  public var fraction: Double {
    guard totalBytes > 0 else { return 0 }
    return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
  }

  public var percent: Int { Int((fraction * 100).rounded()) }

  /// False while the total size is still unknown — a retry starts before any
  /// header has come back, and "0%" frozen on screen for two minutes reads as a
  /// hang. The block then shows an indeterminate bar instead of a fake number.
  public var isDeterminate: Bool { totalBytes > 0 }

  /// A download that has started but cannot report a size yet.
  public static let unknown = ModelDownloadProgress(receivedBytes: 0, totalBytes: 0)

  /// "700 MB de 1,1 GB". Formatted with `ByteCountFormatter`, so the decimal
  /// separator follows the user's locale — the same formatter `ModelStatus`
  /// already uses for the ready state.
  public var detail: String {
    guard isDeterminate else { return "" }
    switch unit {
    case .bytes:
      return "\(Self.format(receivedBytes)) de \(Self.format(totalBytes))"
    case .files:
      return "arquivo \(max(receivedBytes, 1)) de \(totalBytes)"
    }
  }

  static func format(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: max(0, bytes))
  }
}

/// The model status block, one case per variant in DESIGN-HANDOFF.md §1.
///
/// `pending` is a FOURTH case the mockup does not draw. It is reachable and had
/// to be added: the app does not download the model at launch — the first
/// dictation does (see `Fala doctor`) — so between a fresh install and the first
/// press there is a real condition that is neither "pronto" nor "baixando". The
/// alternative was to render "pronto" over an empty disk, which is the kind of
/// lie the doctor command exists to prevent.
public enum ModelBlock: Sendable, Equatable {
  case ready(detail: String)
  case downloading(ModelDownloadProgress)
  /// Already on disk, being loaded into memory. Distinct from `downloading`
  /// because nothing is being fetched — see `ModelDownloadStage.loading`.
  case loading
  case pending
  case failed

  /// Product name as the mockup writes it. Still the DEFAULT, because Parakeet
  /// is the [CONFIRMED] default engine — but no longer the only possible answer.
  public static let modelName = "Parakeet"

  /// The block's headline, naming the engine it is actually reporting on.
  ///
  /// `engine` is a PARAMETER because this string used to hardcode "Parakeet":
  /// with Cohere selected the popover read "Modelo Parakeet · pronto" over a
  /// status measured in Cohere's directory. The status was right and the name
  /// was wrong, which is worse than either being wrong alone — it looked like
  /// the engine switch had not taken effect.
  ///
  /// Pass `TranscriptionEngineChoice.displayName`; there is no default, so a new
  /// call site cannot silently reintroduce the constant.
  public func title(engine: String) -> String {
    switch self {
    case .ready:
      return "Modelo \(engine) · pronto"
    case .downloading(let progress):
      guard progress.isDeterminate else { return "Baixando modelo…" }
      // No percentage for file counts: 1 of 21 is 5% for as long as the biggest
      // file takes, and a number that sits still is worse than no number.
      return progress.unit == .files
        ? "Baixando modelo…"
        : "Baixando modelo… \(progress.percent)%"
    case .loading:
      return "Carregando o modelo \(engine)…"
    case .pending:
      return "Modelo \(engine) · baixa no primeiro uso"
    case .failed:
      return "Falha ao baixar o modelo \(engine)"
    }
  }

  /// The trailing detail ("1,1 GB local", "700 MB de 1,1 GB"), empty when there
  /// is nothing honest to put there.
  public var detail: String {
    switch self {
    case .ready(let detail):
      return detail.isEmpty ? "" : "\(detail) local"
    case .downloading(let progress):
      return progress.detail
    case .loading, .pending, .failed:
      return ""
    }
  }

  public var symbol: String {
    switch self {
    case .ready: return FalaSymbol.processor
    // The processor symbol, not the download arrow: nothing is being fetched,
    // and the arrow is what made this read as a second download.
    case .loading: return FalaSymbol.processor
    case .downloading, .pending: return FalaSymbol.download
    case .failed: return FalaSymbol.error
    }
  }

  /// Which of the six states tints the block. The view resolves the actual color
  /// through `theme.style(for:)`, so no color is named here.
  public var stateKind: StateKind {
    switch self {
    case .ready: return .success
    case .downloading, .loading: return .transcribing
    case .pending: return .idle
    case .failed: return .error
    }
  }

  /// Only the failed variant offers an action (mockup: "Tentar novamente").
  public var actionTitle: String? {
    self == .failed ? "Tentar novamente" : nil
  }

  public var isDownloading: Bool {
    if case .downloading = self { return true }
    return false
  }

  /// Whether the block is showing work in progress of any kind — a transfer OR a
  /// load. `isDownloading` deliberately stays narrow: callers that mean "bytes
  /// are moving" must not accidentally catch a load.
  public var isBusy: Bool {
    self == .loading || isDownloading
  }

  /// `nil` while a download is running with no size yet — the view then draws an
  /// indeterminate bar rather than a 0%-wide determinate one.
  public var progressFraction: Double? {
    guard case .downloading(let progress) = self, progress.isDeterminate else { return nil }
    return progress.fraction
  }

  /// What is on disk right now. Nothing here downloads anything.
  public static func onDisk(_ status: ModelStatus) -> ModelBlock {
    status.isPresent ? .ready(detail: status.formattedSize ?? "") : .pending
  }
}
