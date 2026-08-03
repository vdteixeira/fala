# Spike 0 — Validação do motor de ASR (PT-BR)

Antes de qualquer código de produção, precisamos medir o WER (taxa de erro por
palavra) com a **sua voz**, em PT-BR com jargão de TI. O resultado decide o
motor do app (SPEC.md, NFR-2):

- **WER ≤ 12%** e jargão estável → o motor pode ser o primário.
- **WER > 12–15%** ou jargão quebrando → avaliamos WhisperKit large-v3-turbo.

O harness mede **dois motores** sobre exatamente o mesmo áudio e imprime a
comparação lado a lado:

- **Parakeet TDT v3** — o motor atual. Não consegue forçar português: o
  parâmetro `language` da FluidAudio nesse caminho é um filtro de ESCRITA
  (latino × cirílico), não trava o idioma (SPEC.md FR-7).
- **Cohere Transcribe** — o candidato. Injeta `<|pt|>` duas vezes no prefill do
  decoder, ou seja, trava o idioma de verdade. É por isso que ele está na mesa.

O número que decide é o **WER do subconjunto com jargão**, não o agregado: o
agregado é diluído pelas frases sem jargão (SPEC.md §6, Run 1: 11,4% agregado
contra 13,8% com jargão — lados opostos da linha do gate).

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

> **Lição da Run 1 (02/08/2026):** escreva as frases de referência **antes** de
> gravar e leia-as em voz alta. Duas referências da Run 1 nasceram do `--suggest`
> e foram renomeadas sem correção — deram 0% de WER por construção e sozinhas
> seguraram o resultado abaixo do limite do gate. Grave tudo numa sessão só, com
> o mesmo microfone, e repita 3 vezes as frases que falharam.

## 2. Escreva a referência

Para cada `NNN.wav`, crie `NNN.txt` com a transcrição exata do que você disse
(uma linha, com o jargão grafado do jeito certo: "deploy", "Kubernetes"...).

Atalho — gere rascunhos com o próprio modelo e **corrija**:

```bash
swift run FalaSpike spike/audio --suggest
```

Isso escreve `NNN.txt.suggested` com a hipótese crua do ASR. Abra cada um,
corrija contra o que você realmente falou e renomeie para `.txt`:

```bash
cd spike/audio && for f in *.txt.suggested; do mv "$f" "${f%.suggested}"; done
```

⚠️ Renomear sem corrigir invalida a medição: o rascunho é a saída do modelo,
então usá-lo como referência dá 0% de WER e o gate do NFR-2 perde o sentido.

O `--suggest` usa **um** motor só (o primeiro de `--engines`, por padrão o
Parakeet). Dois rascunhos discordantes seriam só duas coisas para jogar fora.

## 3. Rode o harness

```bash
swift run FalaSpike spike/audio                            # os dois motores
swift run FalaSpike spike/audio --engines parakeet         # só o Parakeet
swift run FalaSpike spike/audio --engines cohere           # só o Cohere
swift run FalaSpike spike/audio --engines parakeet,cohere  # explícito (= padrão)
swift run FalaSpike --help                                 # todas as opções
```

### A flag `--engines`

Lista separada por vírgula: `parakeet`, `cohere`. O padrão é **os dois**.

- Cada motor baixa o próprio modelo na primeira execução: Parakeet ~480 MB,
  **Cohere é um download separado de ~1 GB**. Se você ainda não quer baixar o
  Cohere, use `--engines parakeet`.
- Se um motor não carregar (modelo ausente, rede caindo), o harness **avisa e
  segue com o outro** — a rodada não é perdida. Só aborta se nenhum carregar.
- A comparação é calculada sobre as fixtures que **todos** os motores
  transcreveram, para que uma falha isolada não vire "diferença entre motores".

### O que a saída mostra

Por motor: WER por frase, WER agregado, WER do subconjunto com jargão, quais
termos de jargão foram perdidos e o tempo de processamento. Depois, o bloco
`GATE S0` com os dois critérios (WER e integridade do code-switching) para cada
motor, a tabela `COMPARISON` com o vencedor no subconjunto com jargão e por
quanto, e o veredicto.

Continuam valendo os dois alarmes de integridade: referências idênticas à saída
do modelo e nunca editadas são marcadas como **UNVERIFIED**, e abaixo de 300
palavras de referência o harness avisa que a amostra é pequena demais para
separar 11% de 15%.

Registre o número em SPEC.md §6 e feche o GATE S0.
