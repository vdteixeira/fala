import FalaKit
import Foundation

// Phase 0 stub. Real CLI (setup/doctor/models/install) is Phase 1, T1.9 (FR-21).
let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "doctor":
  print("fala doctor: not implemented yet (Phase 1, T1.9)")
  print("Will report: microphone, Accessibility, model presence, hotkey status.")
case "--version":
  print("fala \(FalaKitInfo.version)")
default:
  print(
    """
    fala \(FalaKitInfo.version) — ditado local PT-BR para macOS (Apple Silicon)

    Comandos disponíveis nesta fase:
      doctor      (stub — chega na Fase 1)
      --version

    Veja TASKS.md para o plano por fases.
    """
  )
}
