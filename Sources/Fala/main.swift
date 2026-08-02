import FalaKit
import Foundation

// Phase 1 CLI. Menu-bar UI is Phase 2 (TASKS.md T2.2).
// User-facing strings are pt-BR by project rule; identifiers stay English.

/// Reports whether the app can actually dictate, and what to fix if not (FR-21).
///
/// Deliberately side-effect free: it never prompts for permissions, so it can be
/// run repeatedly while diagnosing.
func runDoctor() {
  let checker = SystemPermissionChecker()

  print("fala doctor\n")

  print("Permissões:")
  for permission in Permission.allCases {
    let granted = checker.isGranted(permission)
    print("  \(granted ? "✓" : "✗") \(permission.displayName) — \(permission.rationale)")
  }

  print("\nAtalho:")
  let hotkey = Hotkey.rightOption
  print("  Tecla: \(hotkey.displayName)")
  if hotkey.conflictsWithSystemShortcut {
    print("  ⚠︎ Conflita com um atalho do sistema.")
  }

  print("\nModelo:")
  print("  Motor: Parakeet TDT v3 (FluidAudio 0.15.5)")
  print("  ⚠︎ GATE S0 em aberto — veja SPEC.md §6 antes de confiar na precisão.")

  let missing = checker.missingPermissions
  print("")
  if missing.isEmpty {
    print("Tudo pronto para ditar.")
  } else {
    print("Faltam permissões: \(missing.map(\.displayName).joined(separator: ", "))")
    print("Conceda em Ajustes do Sistema › Privacidade e Segurança:")
    for permission in missing {
      if let url = permission.settingsURL {
        print("  \(permission.displayName): \(url.absoluteString)")
      }
    }
    // The trap that wastes the most debugging time — see CLAUDE.md.
    if missing.contains(.accessibility) {
      print(
        """

        Nota: rodando pelo Terminal, a permissão de Acessibilidade é concedida ao
        Terminal, não ao Fala. Para testar atalho e injeção de texto, use um .app
        assinado.
        """)
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
    print("Pedindo acesso ao microfone…")
    guard await permissions.requestMicrophoneAccess() else {
      print("Acesso ao microfone negado. Conceda em Ajustes do Sistema e tente de novo.")
      return
    }
  }

  do {
    let capture = try AudioCapture()
    let engine = ParakeetEngine()
    let dictionary = try? JargonDictionary.loadDefault()

    print("Carregando o modelo (baixa ~1,1 GB na primeira vez)…")
    try await engine.prepare()

    print("Gravando por \(Int(seconds))s — fale agora…")
    try await capture.start()
    try await Task.sleep(for: .seconds(seconds))
    let audio = try await capture.stop()

    print(String(format: "Capturado: %.1fs de áudio. Transcrevendo…\n", audio.duration))
    let transcript = try await engine.transcribe(audio)

    let raw = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty {
      print("(nenhuma fala reconhecida)")
      return
    }

    print("Transcrição:  \(raw)")
    if let dictionary {
      let corrected = dictionary.apply(to: raw)
      if corrected != raw {
        print("Com dicionário: \(corrected)")
      }
    }
    print(
      String(
        format: "\n(%.0f ms de processamento para %.1fs de áudio)",
        transcript.processingTime * 1000, transcript.audioDuration))
  } catch {
    print("Falhou: \(error)")
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "doctor":
  runDoctor()
case "listen":
  let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 5
  await runListen(seconds: seconds)
case "--version":
  print("fala \(FalaKitInfo.version)")
default:
  print(
    """
    fala \(FalaKitInfo.version) — ditado local PT-BR para macOS (Apple Silicon)

    Comandos:
      doctor             verifica permissões, atalho e modelo
      listen [segundos]  grava do microfone e transcreve (padrão: 5s)
      --version

    Fase 1 em construção — veja TASKS.md.
    """
  )
}
