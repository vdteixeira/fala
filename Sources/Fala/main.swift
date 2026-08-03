import Darwin
import FalaKit
import Foundation

/// Where the app mirrors its output when it has no terminal.
///
/// Launched with `open`, the process is detached from any TTY and everything it
/// prints goes nowhere — which is exactly how it must be launched for TCC to see
/// it as Fala.app rather than as Terminal. Without this the app is undiagnosable
/// in the one mode where its permissions actually work.
///
/// Status lines only: permissions, states, error messages. NEVER a transcript,
/// never audio (CLAUDE.md). `Fala listen`'s transcript output is TTY-only.
let logFileURL = FileManager.default
  .homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Logs/Fala/fala.log")

let hasTerminal = isatty(STDOUT_FILENO) != 0

/// Prints, and mirrors to the log file when there is no terminal to print to.
func say(_ message: String) {
  print(message)
  guard !hasTerminal else { return }
  let line = message + "\n"
  let directory = logFileURL.deletingLastPathComponent()
  try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  if let handle = try? FileHandle(forWritingTo: logFileURL) {
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  } else {
    try? line.write(to: logFileURL, atomically: true, encoding: .utf8)
  }
}

// Phase 1 CLI. Menu-bar UI is Phase 2 (TASKS.md T2.2).
// User-facing strings are pt-BR by project rule; identifiers stay English.

/// Reports whether the app can actually dictate, and what to fix if not (FR-21).
///
/// Deliberately side-effect free: it never prompts for permissions, so it can be
/// run repeatedly while diagnosing.
///
/// `@MainActor` because `Preferences` is: the hotkey it reports must be the one
/// the app actually listens for.
@MainActor
func runDoctor() {
  let checker = SystemPermissionChecker()

  say("fala doctor\n")

  say("Permissões:")
  for permission in Permission.allCases {
    let granted = checker.isGranted(permission)
    say("  \(granted ? "✓" : "✗") \(permission.displayName) — \(permission.rationale)")
  }

  say("\nAtalho:")
  // The user's choice, not the default — `doctor` reporting a key the app does
  // not listen for is worse than reporting nothing.
  let hotkey = Preferences().hotkey
  say("  Tecla: \(hotkey.displayName)")
  if hotkey.conflictsWithSystemShortcut {
    say("  ⚠︎ Conflita com um atalho do sistema.")
  }

  say("\nModelo:")
  say("  Motor: Parakeet TDT v3 (FluidAudio 0.15.5)")
  let model = ModelStatus.current()
  if model.isPresent {
    say("  ✓ Baixado (\(model.formattedSize ?? "tamanho desconhecido"))")
  } else if let problem = model.problemMessage {
    // Distinguishes "never downloaded" from "downloaded and broken" — an
    // interrupted transfer used to report as ready.
    say("  ✗ \(problem)")
  } else {
    say("  ✗ Não baixado — a primeira ditada vai baixá-lo (alguns minutos).")
  }
  say("  ⚠︎ GATE S0 em aberto — veja SPEC.md §6 antes de confiar na precisão.")

  // Loading the dictionary is also the check that the app's resource bundle was
  // packaged: without it `Bundle.module` traps, and no `try?` can catch that.
  // Goes through the STORE, not loadDefault(), so the user's override file and
  // any complaint about it actually surface (FR-9).
  say("\nDicionário de jargão:")
  if let status = try? JargonDictionaryStore().load() {
    say("  \(status.isHealthy ? "✓" : "✗") \(status.summary)")
    say("  \(status.fileSummary)")
    for warning in status.warnings {
      say("  ⚠︎ \(warning)")
    }
  } else {
    say("  ✗ Não carregou — o recurso não foi empacotado no app.")
  }

  let missing = checker.missingPermissions
  say("")
  if missing.isEmpty && model.isPresent {
    say("Tudo pronto para ditar.")
  } else if missing.isEmpty {
    say("Permissões OK. O modelo será baixado na primeira ditada.")
  } else {
    say("Faltam permissões: \(missing.map(\.displayName).joined(separator: ", "))")
    say("Conceda em Ajustes do Sistema › Privacidade e Segurança:")
    for permission in missing {
      if let url = permission.settingsURL {
        say("  \(permission.displayName): \(url.absoluteString)")
      }
    }
    // The two traps that waste the most debugging time — see CLAUDE.md and
    // docs/architecture.md. The message differs by how the process was launched,
    // because the fix differs.
    if missing.contains(.accessibility) {
      if hasTerminal {
        say(
          """

          Você está rodando pelo Terminal. O macOS atribui a Acessibilidade ao
          processo RESPONSÁVEL, que nesse caso é o Terminal — a permissão do
          Fala.app não é consultada, mesmo que esteja marcada. Use:

            ./scripts/run-app.sh doctor
          """)
      } else {
        say(
          """

          Rodando como Fala.app e ainda sem Acessibilidade. A causa mais comum é a
          assinatura ad-hoc: ela deriva da própria binária, então QUALQUER rebuild
          gera uma identidade nova e o macOS descarta a permissão concedida.

          Para reconceder: em Ajustes do Sistema › Privacidade e Segurança ›
          Acessibilidade, REMOVA o Fala (botão −) e adicione de novo. Só marcar e
          desmarcar não basta — a entrada antiga aponta para a identidade velha.
          """)
      }
    }
  }
}

/// Records for a fixed number of seconds, transcribes, and prints the result.
///
/// This is the manual end-to-end check for the capture → resample → ASR →
/// dictionary path while the hotkey and injection halves are still unbuilt. It
/// needs only microphone permission, so it works from a plain terminal — unlike
/// injection, which needs Accessibility and therefore a signed .app bundle.
///
/// Printing the transcript is the point of the command (the user asked for it on
/// their own terminal), not logging: nothing here writes to a file or os_log.
func runListen(seconds: Double) async {
  let permissions = SystemPermissionChecker()
  if !permissions.isGranted(.microphone) {
    say("Pedindo acesso ao microfone…")
    guard await permissions.requestMicrophoneAccess() else {
      say("Acesso ao microfone negado. Conceda em Ajustes do Sistema e tente de novo.")
      return
    }
  }

  do {
    let capture = try AudioCapture()
    let engine = ParakeetEngine()
    let dictionary = try? JargonDictionary.loadDefault()

    say("Carregando o modelo (baixa ~480 MB na primeira vez)…")
    try await engine.prepare()

    say("Gravando por \(Int(seconds))s — fale agora…")
    try await capture.start()
    try await Task.sleep(for: .seconds(seconds))
    let audio = try await capture.stop()

    say(String(format: "Capturado: %.1fs de áudio. Transcrevendo…\n", audio.duration))
    let transcript = try await engine.transcribe(audio)

    let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
      say("(nenhuma fala reconhecida)")
      return
    }

    print("Transcrição:  \(raw)")
    if let dictionary {
      let corrected = dictionary.apply(to: raw)
      if corrected != raw {
        print("Com dicionário: \(corrected)")
      }
    }
    say(
      String(
        format: "\n(%.0f ms de processamento para %.1fs de áudio)",
        transcript.processingTime * 1000, transcript.audioDuration))
  } catch {
    say("Falhou: \(error)")
  }
}

/// The real thing (SPEC.md US-1): hold the hotkey, speak, release, and the text
/// lands at the cursor in whatever app has focus.
///
/// MUST be run from a signed .app bundle (`./scripts/make-app.sh`). From a
/// terminal, macOS grants Accessibility to the TERMINAL, so the event tap is
/// created against the wrong identity and never fires — see CLAUDE.md.
@MainActor
func runDictation() async {
  let permissions = SystemPermissionChecker()

  if !permissions.isGranted(.microphone) {
    say("Pedindo acesso ao microfone…")
    guard await permissions.requestMicrophoneAccess() else {
      say("Acesso ao microfone negado.")
      return
    }
  }
  guard permissions.isGranted(.accessibility) else {
    say("Falta a permissão de Acessibilidade — sem ela o atalho não funciona.")
    say("Conceda em Ajustes do Sistema › Privacidade e Segurança › Acessibilidade,")
    say("e rode a partir do Fala.app (./scripts/make-app.sh), não pelo Terminal.")
    return
  }

  do {
    let capture = try AudioCapture()
    let engine = ParakeetEngine()
    let dictionary =
      (try? JargonDictionaryStore().load())?.dictionary
      ?? (try? JargonDictionary.loadDefault())
    let hotkeyChoice = Preferences().hotkey

    say("Carregando o modelo…")
    try await engine.prepare()

    let coordinator = DictationCoordinator(
      capture: capture,
      engine: engine,
      injector: ClipboardInjector(),
      dictionary: dictionary)

    let hotkey = HotkeyManager(hotkey: hotkeyChoice)
    try hotkey.start()

    // States, so the terminal shows what the pill overlay will show in Phase 2.
    // Prints the STATE, never the transcript.
    let states = await coordinator.states()
    Task {
      for await state in states {
        switch state {
        case .recording: say("● gravando…")
        case .transcribing(let seconds):
          say(String(format: "… transcrevendo (%.1fs capturados)", seconds))
        case .success: say("✓ inserido")
        case .failure(let message): say("✗ \(message)")
        case .idle: break
        }
      }
    }

    say("Pronto. Segure \(hotkeyChoice.displayName), fale, e solte.")
    say("Ctrl+C para sair.\n")

    // A tap disabled by macOS mid-utterance is re-armed, but the key-up that
    // happened while it was dead is gone, so the recogniser forces a release and
    // the recording is CUT SHORT. That produces a truncated transcript which
    // looks exactly like a bad model. Report the counter so the two are
    // distinguishable — this is the likeliest cause if captured seconds come out
    // far below how long you actually held the key.
    var reportedRecoveries = 0
    for await phase in hotkey.phases {
      await coordinator.handle(phase)
      let recoveries = hotkey.tapDisabledRecoveries
      if recoveries > reportedRecoveries {
        reportedRecoveries = recoveries
        say("⚠︎ o macOS desativou o atalho \(recoveries)x — a gravação foi cortada")
      }
    }
  } catch {
    say("Falhou ao iniciar: \(error)")
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())

// NFR-4: refuse before anything expensive. `doctor` and `--version` are exempt so
// a refused user can still produce a diagnostic to send back.
if let refusal = HostPlatform().refusal,
  arguments.first != "doctor", arguments.first != "--version"
{
  say(refusal.title)
  say("")
  say(refusal.explanation)
  exit(1)
}

// NO ARGUMENT = MENU BAR. LaunchServices passes none, so double-clicking
// Fala.app in the Finder used to fall through to `default`, print the CLI usage
// to a stdout nobody can see, and exit — the app simply did nothing. That made
// the whole .dmg useless for anyone who did not know to pass `menubar`.
switch arguments.first ?? "menubar" {
case "doctor":
  runDoctor()
case "listen":
  let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 5
  await runListen(seconds: seconds)
case "run":
  await runDictation()
case "menubar":
  // Never returns: NSApplication.run() owns the process from here.
  FalaMenuBarApp.run()
case "--version":
  say("fala \(FalaKitInfo.version)")
default:
  say(
    """
    fala \(FalaKitInfo.version) — ditado local PT-BR para macOS (Apple Silicon)

    Comandos:
      menubar            app da barra de menus (o produto de verdade)
      run                ditado por atalho, sem UI (exige Fala.app)
      doctor             verifica permissões, atalho e modelo
      listen [segundos]  grava do microfone e transcreve (padrão: 5s)
      --version

    Fase 1 em construção — veja TASKS.md.
    """
  )
}
