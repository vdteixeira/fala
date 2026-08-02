# Fala

Ditado por voz **100% local** para macOS (Apple Silicon), feito para português
brasileiro com jargão de TI em inglês ("deploy", "endpoint", "Kubernetes").

Segure uma tecla (⌥ direita), fale, solte — o texto aparece onde estiver o seu
cursor, em qualquer app. Nada de nuvem: o áudio e as transcrições **nunca saem
do seu Mac** (LGPD por construção — sem telemetria, sem contas).

## Status

Em construção, por fases (veja TASKS.md):

- **Spike 0** — validação do motor de ASR com áudio real (`spike/README.md`) — **GATE ABERTO**, a Run 1 foi invalidada
- **Fase 1** — MVP: tecla → captura → transcrição (Parakeet TDT v3 via FluidAudio, ANE) → texto no cursor — código pronto, ← **falta a verificação manual**
- **Fase 2** — UI (menu bar, pill overlay, ajustes, histórico), dicionário de jargão editável
- **Fase 3** — assinatura, notarização, distribuição em .dmg

## Requisitos

- macOS 14+ · Apple Silicon (M1–M4) · Swift 6+

## Como testar

```bash
swift build                      # compilar
./scripts/test.sh                # 193 testes unitários
swift run Fala doctor            # permissões, atalho e modelo
swift run Fala listen 6          # grava 6s do microfone e transcreve
swift run FalaSpike spike/audio  # mede WER nas suas gravações
```

`listen` roda do terminal e só precisa do microfone: microfone → 16 kHz →
Parakeet → dicionário de jargão. Baixa o modelo (~480 MB) na primeira vez.

### Ditado de verdade

Segurar a tecla e o texto aparecer no cursor exige Acessibilidade, e o macOS
concede essa permissão ao *processo responsável* — pelo Terminal, quem a recebe é
o Terminal, não o Fala. Por isso é preciso um `.app`:

```bash
./scripts/make-app.sh                      # gera build/Fala.app assinado
# conceda Acessibilidade a Fala.app em
# Ajustes do Sistema › Privacidade e Segurança › Acessibilidade
./scripts/run-app.sh run                   # segure ⌥ direita, fale, solte
```

A assinatura é ad-hoc, então a identidade muda a cada rebuild e o macOS pode
descartar a permissão — se o atalho parar de responder depois de recompilar,
remova e adicione o app de novo na lista. Certificado Developer ID resolve isso
de vez (Fase 3).

Use `./scripts/test.sh`, não `swift test`: a biblioteca de testes só existe no
toolchain completo do Xcode, e o wrapper cuida disso sem contaminar o `.build`.

Documentação para desenvolvimento: CLAUDE.md, SPEC.md, TASKS.md, DESIGN.md
(em inglês). Guias de uso em `docs/pt-BR/` chegam na Fase 2.
