# Fala

Ditado por voz **100% local** para macOS (Apple Silicon), feito para português
brasileiro com jargão de TI em inglês ("deploy", "endpoint", "Kubernetes").

Segure uma tecla (⌥ direita), fale, solte — o texto aparece onde estiver o seu
cursor, em qualquer app. Nada de nuvem: o áudio e as transcrições **nunca saem
do seu Mac** (LGPD por construção — sem telemetria, sem contas).

## Status

Em construção, por fases (veja TASKS.md):

- **Spike 0** — validação do motor de ASR com áudio real (veja `spike/README.md`) ← estamos aqui
- **Fase 1** — MVP: tecla → captura → transcrição (Parakeet TDT v3 via FluidAudio, ANE) → texto no cursor
- **Fase 2** — UI (menu bar, pill overlay, ajustes, histórico), dicionário de jargão editável
- **Fase 3** — assinatura, notarização, distribuição em .dmg

## Requisitos

- macOS 14+ · Apple Silicon (M1–M4) · Swift 6+

## Desenvolvimento

```bash
swift build          # compilar
swift test           # testes
swift run Fala       # CLI (stub na fase atual)
```

Documentação para desenvolvimento: CLAUDE.md, SPEC.md, TASKS.md, DESIGN.md
(em inglês). Guias de uso em `docs/pt-BR/` chegam na Fase 2.
