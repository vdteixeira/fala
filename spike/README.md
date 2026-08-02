# Spike 0 — Validação do motor de ASR (PT-BR)

Antes de qualquer código de produção, precisamos medir o WER (taxa de erro por
palavra) do Parakeet TDT v3 com a **sua voz**, em PT-BR com jargão de TI. O
resultado decide o motor do app (SPEC.md, NFR-2):

- **WER ≤ 12%** e jargão estável → Parakeet segue como motor primário.
- **WER > 12–15%** ou jargão quebrando → avaliamos WhisperKit large-v3-turbo.

## 1. Grave 15–20 frases

Grave cada frase como um arquivo WAV separado nesta pasta, em `spike/audio/`
(a pasta é git-ignored — seu áudio nunca vai para o repositório).

Sugestões de frases (misture ditado natural + jargão pesado):

1. "Fazer o deploy no endpoint do Kubernetes depois do merge."
2. "Cria uma branch nova a partir da main e abre o pull request."
3. "O pipeline quebrou no step de build, faz o rollback do último commit."
4. "Sobe o container do Postgres com o Docker Compose no cluster de staging."
5. "O timeout do endpoint de autenticação está em trezentos milissegundos."
6. Frases suas do dia a dia — e-mails, mensagens, documentação ditada.

Dicas: microfone interno do Mac (não AirPods), ambiente normal de trabalho,
fale no ritmo real de ditado. Frases de 5 a 15 segundos.

### Como gravar em WAV

QuickTime grava em .m4a; converta com afconvert (já vem no macOS):

```bash
afconvert entrada.m4a spike/audio/001.wav -d LEI16 -f WAVE
```

Ou grave direto em WAV com o sox (`brew install sox`):

```bash
rec spike/audio/001.wav trim 0 15
```

## 2. Escreva a referência

Para cada `NNN.wav`, crie `NNN.txt` com a transcrição exata do que você disse
(uma linha, com o jargão grafado do jeito certo: "deploy", "Kubernetes"...).

## 3. Rode o harness

```bash
swift run FalaSpike spike/audio
```

Na primeira execução ele baixa o modelo (~1,1 GB). A saída mostra WER por
frase, WER agregado, latência de processamento, jargão perdido e o veredicto
segundo o gate do NFR-2. Registre o número em SPEC.md §6 e feche o GATE S0.
