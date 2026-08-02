import CoreFoundation
import CoreGraphics
import Foundation

// MARK: - Errors

public enum HotkeyError: Error, Equatable, Sendable {
  /// `CGEvent.tapCreate` returned nil.
  ///
  /// The cause is a missing TCC grant: the *responsible* process must be trusted
  /// for Accessibility. Run from a terminal, that process is Terminal and not
  /// Fala (CLAUDE.md), which is why the tap must be verified from a signed .app.
  /// A `.listenOnly` keyboard tap can also be gated by Input Monitoring on some
  /// configurations; Accessibility is documented as subsuming it, and this app
  /// needs Accessibility anyway for injection (FR-11/FR-12).
  case accessibilityDenied
  /// `start()` called while already running.
  case alreadyRunning
  /// The Mach port could not be turned into a run-loop source. Not a permission
  /// problem — resource exhaustion — so it is reported separately.
  case runLoopSourceUnavailable
  /// `start()` called after `shutdown()`. The phase stream is closed for good;
  /// build a new manager.
  case shutDown
}

// MARK: - Event tap seam

/// One thing the tap saw, described WITHOUT `CGEvent`.
///
/// This is the boundary that makes `HotkeyManager` testable: `CGEvent` is
/// neither `Sendable` nor constructible in a meaningful way in a unit test,
/// while `CGKeyCode` and `CGEventFlags` are plain value types. Everything above
/// this line is exercised by `HotkeyManagerTests`; everything below it needs TCC
/// and a signed bundle and is verified by hand.
public enum EventTapSignal: Sendable, Equatable {
  /// A modifier key changed. `flags` is the WHOLE modifier state, not just ours.
  case flagsChanged(keyCode: CGKeyCode, flags: CGEventFlags)
  /// macOS switched the tap off (`.tapDisabledByTimeout` or
  /// `.tapDisabledByUserInput`). Until it is re-enabled, NO events arrive — in
  /// particular the key-up of a key the user is holding right now.
  case tapDisabled
}

/// The `CGEventTap` lifecycle, behind a protocol so `HotkeyManager`'s
/// bookkeeping and its disabled-tap recovery are unit-testable without
/// Accessibility (see the `swift-testing` skill).
///
/// Main-actor isolated because the production implementation installs its
/// run-loop source on the main run loop: install, teardown and callback then all
/// run on the same thread, which is what makes teardown race-free by
/// construction rather than by lock.
@MainActor
public protocol EventTapControlling {
  /// Creates the tap and starts delivering to `handler`. Replaces any tap this
  /// object already installed.
  ///
  /// - Throws: `HotkeyError.accessibilityDenied` when the tap cannot be created.
  func install(handler: @escaping @MainActor @Sendable (EventTapSignal) -> Void) throws

  /// Switches a disabled tap back on. No-op when nothing is installed.
  func reenable()

  /// Removes the tap and its run-loop source.
  func uninstall()
}

// MARK: - HotkeyManager

/// The `CGEventTap` half of the push-to-talk hotkey (SPEC.md FR-1).
///
/// It owns no policy: `HotkeyRecognizer` decides what a flag transition means,
/// this type only delivers events to it and publishes the resulting phases. The
/// split exists because the recogniser is unit-testable and the tap is not.
///
/// ```swift
/// let manager = HotkeyManager(hotkey: .rightOption)
/// try manager.start()
/// for await phase in manager.phases {   // safe from any actor
///   switch phase { case .pressed: …; case .released: … }
/// }
/// ```
///
/// **Delivery.** `phases` is an `AsyncStream` created once in `init`, so an
/// owner can subscribe before `start()` and keep the same stream across
/// stop/start cycles. Buffering is unbounded ON PURPOSE: a dropped `.released`
/// would leave the microphone recording forever, which is the worst failure this
/// type can produce. The stream carries a two-case enum and never a transcript
/// or audio. It supports ONE consumer.
///
/// **Passivity.** The tap is `.listenOnly`, so a held push-to-talk modifier
/// still reaches the frontmost app. Swallowing it is impossible here, not merely
/// avoided (see `SystemEventTap`).
@MainActor
public final class HotkeyManager {
  /// SPEC.md FR-1: right-Option, chosen because little else binds it.
  public static let defaultHotkey: Hotkey = .rightOption

  /// The bound key. Fixed for the lifetime of the manager; rebinding means
  /// building a new one, so a rebind can never land mid-utterance.
  public nonisolated let hotkey: Hotkey

  /// Press/release phases, in order. See the type's doc comment.
  public nonisolated let phases: AsyncStream<HotkeyPhase>

  private nonisolated let continuation: AsyncStream<HotkeyPhase>.Continuation
  private let tap: any EventTapControlling
  private var recognizer: HotkeyRecognizer
  private var running = false
  private var isShutDown = false
  private var recoveries = 0

  public var isRunning: Bool { running }

  /// Whether the recogniser currently believes the key is down. Exposed so the
  /// owner can assert "not recording" invariants and `doctor` can report state.
  public var isHotkeyHeld: Bool { recognizer.isHeld }

  /// How many times macOS disabled the tap and we re-armed it. A non-zero value
  /// in the field means the main run loop is being blocked; it is a diagnostic
  /// counter, deliberately not a log line (no payload, but also no noise).
  public var tapDisabledRecoveries: Int { recoveries }

  /// - Parameters:
  ///   - hotkey: the push-to-talk key (FR-1).
  ///   - tap: injected so tests can drive the whole state machine without TCC.
  public init(
    hotkey: Hotkey = HotkeyManager.defaultHotkey,
    tap: any EventTapControlling = SystemEventTap()
  ) {
    self.hotkey = hotkey
    self.tap = tap
    self.recognizer = HotkeyRecognizer(hotkey: hotkey)
    let (stream, continuation) = AsyncStream<HotkeyPhase>.makeStream()
    self.phases = stream
    self.continuation = continuation
  }

  /// Tears the tap down and closes the stream.
  ///
  /// `isolated deinit` (SE-0371) rather than a plain one, for two reasons the
  /// review caught:
  /// - A plain `deinit` is nonisolated, so it could not call `stop()`. Dropping
  ///   the last reference while the key was held published no `.released`, the
  ///   consumer's `for await` simply ended, and `DictationCoordinator` stayed in
  ///   `.recording` with the microphone live — the same record-forever failure
  ///   this type exists to prevent. It also skipped `tap.uninstall()`, leaking an
  ///   enabled `CGEventTap` when the tap was caller-supplied.
  /// - The C teardown (`CGEvent.tapEnable`, `CFRunLoopRemoveSource` on the MAIN
  ///   run loop, `CFMachPortInvalidate`, `Unmanaged.release`) must not race a
  ///   callback executing on the main thread. Main-actor isolation makes that an
  ///   enforced invariant instead of a comment asking callers to be careful.
  @MainActor deinit {
    stop()
    continuation.finish()
  }

  // MARK: Lifecycle

  /// Installs the tap and begins publishing phases.
  ///
  /// - Throws: `HotkeyError.accessibilityDenied` when the tap cannot be created,
  ///   `.alreadyRunning`, or `.shutDown`.
  public func start() throws {
    guard !isShutDown else { throw HotkeyError.shutDown }
    guard !running else { throw HotkeyError.alreadyRunning }

    // Never inherit "held" from a previous run: the key-up that ended it may
    // have happened while the tap was gone.
    recognizer = HotkeyRecognizer(hotkey: hotkey)
    // Set before installing so an event delivered during installation is not
    // silently dropped by the `running` guard in `handle`.
    running = true
    do {
      try tap.install { [weak self] signal in
        self?.handle(signal)
      }
    } catch {
      running = false
      throw error
    }
  }

  /// Removes the tap. Idempotent, and safe to follow with another `start()`.
  public func stop() {
    guard running else { return }
    running = false
    tap.uninstall()
    // Tearing down while the key is physically down means its key-up will never
    // be seen. Publish the release ourselves or the owner keeps recording.
    yieldIfNeeded(recognizer.reset())
  }

  /// Stops and closes `phases`. Terminal: `start()` afterwards throws
  /// `HotkeyError.shutDown`.
  public func shutdown() {
    stop()
    isShutDown = true
    continuation.finish()
  }

  // MARK: Event handling

  private func handle(_ signal: EventTapSignal) {
    // A real tap cannot deliver after `uninstall()` (the port is invalidated),
    // but the guard makes "stopped means silent" a property of this type rather
    // than of CoreGraphics.
    guard running else { return }

    switch signal {
    case .flagsChanged(let keyCode, let flags):
      yieldIfNeeded(recognizer.handleFlagsChanged(keyCode: keyCode, flags: flags))
    case .tapDisabled:
      recoverFromDisabledTap()
    }
  }

  /// Handles macOS switching the tap off.
  ///
  /// Two causes, both routine: `.tapDisabledByTimeout` (a callback took too long
  /// — a stalled main run loop is enough) and `.tapDisabledByUserInput`. A tap
  /// is NOT re-armed automatically, so without this the hotkey stops working
  /// entirely.
  ///
  /// The re-arm is only half the fix. While the tap was dead no events were
  /// delivered, so if the user was mid-utterance their key-up is simply gone and
  /// the recogniser would stay `held` forever — a microphone that never stops.
  /// `reset()` forces the release, and it is a no-op when the key was already up
  /// so an idle disable never fabricates a phase.
  private func recoverFromDisabledTap() {
    recoveries += 1
    tap.reenable()
    yieldIfNeeded(recognizer.reset())
  }

  private func yieldIfNeeded(_ phase: HotkeyPhase?) {
    guard let phase else { return }
    continuation.yield(phase)
  }
}

// MARK: - Production tap

/// The real `CGEventTap`: PASSIVE, `.flagsChanged` only, on the main run loop.
///
/// Not unit-testable — it needs Accessibility and a signed .app bundle (see the
/// `swift-testing` skill and CLAUDE.md's "known traps"). It is deliberately thin
/// for that reason: every decision worth testing lives in `HotkeyManager`.
///
/// **Run loop.** The source is added to the main run loop in `.commonModes`, so
/// the hotkey keeps working while a menu is tracking. That also pins the
/// callback to the main thread, which is what lets this file be Swift 6 clean
/// with no locks and no `@unchecked Sendable`. The cost is that a blocked main
/// thread can get the tap disabled by timeout — handled, and counted, by
/// `HotkeyManager.tapDisabledRecoveries`. If that counter is ever non-trivial in
/// the field, moving the source to a dedicated run-loop thread is a change to
/// this type alone: the `EventTapControlling` seam hides it from everything else.
@MainActor
public final class SystemEventTap: EventTapControlling {
  private var resources: TapResources?

  public init() {}

  public var isInstalled: Bool { resources != nil }

  public func install(
    handler: @escaping @MainActor @Sendable (EventTapSignal) -> Void
  ) throws {
    uninstall()

    // OWNERSHIP. A `CGEventTapCallBack` is a C function pointer and cannot
    // capture anything, so the handler travels as an opaque `refcon`. The +1
    // taken here is owned by `TapResources`, which releases it in `deinit`
    // AFTER invalidating the port — so no callback can ever dereference a freed
    // context. Each early return below balances the +1 by hand, because no
    // `TapResources` exists yet to do it.
    let context = Unmanaged.passRetained(TapContext(handler: handler)).toOpaque()
    let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue

    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        // PASSIVE (FR-1): a listen-only tap is not in the delivery path at all,
        // so a push-to-talk modifier reaches the frontmost app no matter what
        // this process does — including hanging.
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: Self.callback,
        userInfo: context)
    else {
      Unmanaged<TapContext>.fromOpaque(context).release()
      throw HotkeyError.accessibilityDenied
    }

    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
      CFMachPortInvalidate(port)
      Unmanaged<TapContext>.fromOpaque(context).release()
      throw HotkeyError.runLoopSourceUnavailable
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
    resources = TapResources(port: port, source: source, context: context)
  }

  public func reenable() {
    guard let resources else { return }
    CGEvent.tapEnable(tap: resources.port, enable: true)
  }

  /// Dropping the resources IS the teardown — see `TapResources`.
  public func uninstall() {
    resources = nil
  }

  /// The C entry point.
  ///
  /// Static rather than a file-scope global so it stays main-actor isolated
  /// alongside the rest of this type; converting it to `@convention(c)` happens
  /// at the `tapCreate` call site.
  private static let callback: CGEventTapCallBack = { _, type, event, refcon in
    // Hand the event straight back, untouched. With `.listenOnly` this return
    // value is ignored, but returning the event unmodified keeps the tap passive
    // if the option is ever changed — swallowing the modifier would break every
    // app the user types in.
    let passthrough = Unmanaged.passUnretained(event)
    guard let refcon else { return passthrough }
    let context = Unmanaged<TapContext>.fromOpaque(refcon).takeUnretainedValue()

    // Decode to value types HERE, before crossing into the main actor: `CGEvent`
    // is a non-`Sendable` reference the window server still owns, and handing it
    // to an isolated closure is a data race the compiler rightly rejects.
    // `CGKeyCode` and `CGEventFlags` are plain value types, so the signal is.
    let signal: EventTapSignal?
    switch type {
    case .flagsChanged:
      let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
      signal = .flagsChanged(keyCode: keyCode, flags: event.flags)
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
      signal = .tapDisabled
    default:
      signal = nil
    }
    guard let signal else { return passthrough }

    // The run-loop source lives on the MAIN run loop, so this callback always
    // runs on the main thread. The assumption is structural, and was verified
    // against a real CFRunLoop C callback before being relied on here.
    MainActor.assumeIsolated {
      context.handler(signal)
    }
    return passthrough
  }
}

/// Carrier for the handler across the C boundary.
///
/// Immutable and `Sendable`, so the callback's only interaction with it is
/// reading `handler` — there is no state here to race on.
private final class TapContext: Sendable {
  let handler: @MainActor @Sendable (EventTapSignal) -> Void

  init(handler: @escaping @MainActor @Sendable (EventTapSignal) -> Void) {
    self.handler = handler
  }
}

/// RAII owner of the tap's C-level resources.
///
/// Teardown lives in `deinit` instead of a `stop()` method so it cannot be
/// skipped: dropping the reference tears everything down exactly once, whether
/// that came from `uninstall()`, from a re-`install()`, or from the whole
/// manager being deallocated.
private final class TapResources {
  let port: CFMachPort
  let source: CFRunLoopSource
  /// The +1 on `TapContext` that was handed to the C callback as `refcon`.
  private let context: UnsafeMutableRawPointer

  init(port: CFMachPort, source: CFRunLoopSource, context: UnsafeMutableRawPointer) {
    self.port = port
    self.source = source
    self.context = context
  }

  deinit {
    // Order is load-bearing: stop delivery FIRST, then drop the context the
    // callback dereferences. Releasing the context before invalidating the port
    // is a use-after-free.
    CGEvent.tapEnable(tap: port, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    CFMachPortInvalidate(port)
    Unmanaged<TapContext>.fromOpaque(context).release()
  }
}
