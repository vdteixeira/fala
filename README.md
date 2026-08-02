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

## Como testar

```bash
swift build                      # compilar
./scripts/test.sh                # 125 testes unitários
swift run Fala doctor            # permissões, atalho e modelo
swift run Fala listen 6          # grava 6s do microfone e transcreve
swift run FalaSpike spike/audio  # mede WER nas suas gravações
```

`listen` é o teste ponta a ponta possível hoje: microfone → 16 kHz → Parakeet →
dicionário de jargão. Pede permissão de microfone na primeira execução e baixa o
modelo (~1,1 GB) uma vez.

O ditado real (segurar ⌥ direita e o texto aparecer no cursor) ainda não funciona:
falta o `HotkeyManager`, e a injeção de texto exige permissão de Acessibilidade,
que só pode ser concedida a um `.app` assinado — nunca a um binário rodando pelo
Terminal.

Use `./scripts/test.sh`, não `swift test`: a biblioteca de testes só existe no
toolchain completo do Xcode, e o wrapper cuida disso sem contaminar o `.build`.

Documentação para desenvolvimento: CLAUDE.md, SPEC.md, TASKS.md, DESIGN.md
(em inglês). Guias de uso em `docs/pt-BR/` chegam na Fase 2.
