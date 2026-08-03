# Usando o Fala

## O gesto

Segure o **⌥ direito** (a tecla Option/Alt do lado direito do teclado), fale em
português, e solte.

Enquanto você segura, o Fala só grava. A transcrição começa quando você solta, e
o texto aparece onde estiver o seu cursor — no editor, no navegador, no campo de
busca, em qualquer app.

Duas observações práticas:

- Frases de alguns segundos funcionam melhor. O Fala guarda cerca de 60 segundos
  de áudio; se você passar disso, o começo da fala se perde.
- A tecla é fixa nesta versão. Não dá para trocar o ⌥ direito por outra sem
  recompilar o app.

## A pílula na parte de baixo da tela

Uma faixinha escura aparece centralizada no rodapé para dizer o que está
acontecendo. Ela não recebe cliques e nunca rouba o foco do que você está
fazendo.

| O que aparece | O que significa |
| --- | --- |
| Um risquinho quase invisível | Em repouso. Some sozinho em ~2 s. |
| "Ouvindo…" com barras animadas | Está gravando. Continue falando. |
| "Transcrevendo…" com selo "no dispositivo" | Processando o áudio, no seu Mac. |
| "Texto inserido" | Deu certo. Some em ~1,2 s. |
| Mensagem em vermelho | Algo falhou. Some em ~2,5 s. |
| Aviso em âmbar | Problema de microfone (veja o fim desta página). |

As mensagens de erro mais comuns:

- **"Campo protegido — injeção bloqueada."** — você estava num campo de senha.
- **"Não entendi o que foi dito."** — o modelo não reconheceu nenhuma fala.
- **"Nada foi capturado."** — o microfone não entregou áudio.
- **"Não consegui inserir o texto."** — o app de destino recusou a colagem.
- **"A transcrição falhou."** — na primeira ditada, quase sempre é o modelo de
  voz que ainda não foi baixado. Veja [instalacao.md](instalacao.md).

Se a mensagem sumiu antes de você ler, ela fica guardada no menu do Fala, com um
botão "Dispensar".

## O menu na barra de menus

O Fala não tem ícone no Dock nem janela principal. O ícone de quatro barrinhas
na barra de menus é a única porta de entrada. Clicando nele:

- **Ditado ativado / desativado** — a chave desliga a captura de verdade: com ela
  desligada, o microfone não é aberto nem quando você segura a tecla.
- **Permissões pendentes** — faixa âmbar com o botão "Conceder", quando falta
  algo (veja [permissoes.md](permissoes.md)).
- **Última falha** — a mensagem da ditada que deu errado, até você dispensar.
- **Estado do modelo** — "pronto" com o tamanho em disco, ou o que falta.
- **Recentes** — as últimas 4 ditadas, cada uma com um botão de copiar. A cópia
  fica só neste Mac: não vai para a Área de Transferência Universal (seus outros
  aparelhos Apple) e é marcada para não entrar em gerenciadores de histórico de
  cópia.
- **Abrir Ajustes** e **Abrir Histórico** aparecem apagados de propósito: essas
  janelas ainda não existem.
- **Sair do Fala** (⌘Q com o menu aberto).

## Dicionário de jargão

O reconhecedor erra sobretudo em termos técnicos em inglês. O dicionário corrige
essas trocas de forma determinística — "posterg" vira "Postgres", "docker com
pose" vira "Docker Compose". São 43 entradas de fábrica.

O seu arquivo fica em:

```
~/Library/Application Support/Fala/it-jargon.json
```

Ele é criado na primeira execução, já com as instruções escritas dentro dele. O
que você escreve ali é **mesclado por cima** do dicionário embutido: o Fala nunca
sobrescreve o seu arquivo. Em `entries` você adiciona ou substitui trocas; em
`disable` você desliga trocas de fábrica que não gosta.

Cada entrada tem uma segurança:

- `safe` — o texto procurado não é palavra do português, então a troca não tem
  como estragar uma frase correta.
- `contextual` — só troca quando uma palavra do contexto (por exemplo "docker")
  estiver a até três palavras de distância.
- `risky` — fica desligada.

As trocas valem por palavra inteira, ignorando maiúsculas e acentos.

**As mudanças valem na próxima vez que o Fala abrir.** E se o arquivo tiver um
erro de sintaxe, o Fala volta a usar só o dicionário embutido e explica o motivo
no `doctor` — a ditada não para por causa disso.

## Histórico

Cada ditada inserida com sucesso é guardada em:

```
~/Library/Application Support/Fala/history.json
```

É um JSON legível, que só o seu usuário consegue abrir, limitado às 500 ditadas
mais recentes. Ditadas bloqueadas ou que falharam não entram.

O menu mostra as 4 últimas. A janela de histórico ainda não existe, então para
apagar tudo, feche o Fala e apague o arquivo (e o `history-anterior.json`, se
existir).

## Desfazer

**Nesta versão não há botão de desfazer.** Se a transcrição saiu ruim, use ⌘Z no
próprio app onde o texto entrou.

E vale entender o limite, porque ele não vai mudar quando o botão existir: o
texto não é mais do Fala. Ele está dentro do documento de outro aplicativo, sob
o controle do "desfazer" daquele aplicativo. Tudo o que dá para fazer é **pedir**
— enviar um ⌘Z —, nunca garantir. Na prática:

- Se você digitou alguma coisa depois da ditada, o ⌘Z desfaz o que você digitou,
  não a ditada.
- Alguns apps agrupam ou dividem as etapas de desfazer de um jeito próprio.
- Alguns campos (terminais, muitas caixas de texto na web) simplesmente não têm
  desfazer.

## Campos de senha

Quando o macOS liga a "entrada segura de teclado" — campo de senha em foco, tela
de bloqueio, prompt de VPN, Terminal com entrada segura ligada —, o Fala se
recusa a inserir qualquer coisa e mostra "Campo protegido — injeção bloqueada.".
O áudio até foi transcrito, mas nada é colado nem digitado. Isso é proposital.

Se **todas** as ditadas começarem a ser bloqueadas mesmo longe de um campo de
senha, é porque algum aplicativo deixou a entrada segura ligada (acontece).
Feche ou reative a janela do gerenciador de senhas, ou desligue "Entrada Segura
de Teclado" no menu do Terminal.

## Cuidado com terminais e quebras de linha

Normalmente o Fala insere o texto pela área de transferência, com um ⌘V, e
devolve depois o que você tinha copiado antes. Quando isso não é possível — por
exemplo, quando a área de transferência guarda algo que o Fala não conseguiria
devolver intacto, como uma faixa de planilha —, ele digita o texto tecla por
tecla.

E aí está o risco: **digitando, uma quebra de linha é um Return de verdade**. Num
prompt de shell, isso executa a linha.

O Fala protege o **Terminal.app** e o **iTerm2**: nesses dois, ele se recusa a
digitar um texto com mais de uma linha, perdendo a ditada em vez de arriscar.

Ele **não protege** os outros terminais — Ghostty, Warp, Alacritty, kitty,
WezTerm e afins. Neles, dite frases curtas de uma linha só, ou dite num editor e
copie de lá.

## Microfone: evite fones Bluetooth

Fones Bluetooth usados como microfone forçam o link para o perfil hands-free
(HFP): 8 ou 16 kHz, muito comprimidos. O reconhecedor foi treinado com fala de
banda cheia, então a taxa de erro sobe bastante. **Prefira o microfone interno do
Mac.**

Nesta versão não há seletor de microfone dentro do Fala: ele usa a entrada padrão
do sistema, que você escolhe em **Ajustes do Sistema › Som › Entrada**. O aviso
âmbar na pílula existe no app, mas ainda não é acionado — não conte com ele. Se a
qualidade cair de repente, o primeiro lugar para olhar é se a entrada trocou para
um headset.

## Precisão: o que esperar

O caso de uso é português brasileiro com jargão de TI em inglês. O modelo foi
treinado sobretudo com português europeu, e a precisão ainda não foi validada
formalmente neste projeto. Espere erros justamente nos termos técnicos em inglês
— é para isso que existe o dicionário de jargão, e vale a pena alimentá-lo com os
seus.

## Quando nada acontece

- **Segurei a tecla e não apareceu nada** — o Fala pode não estar aberto, o
  ditado pode estar desativado no menu, ou falta Acessibilidade
  ([permissoes.md](permissoes.md)).
- **Não aparece o ícone na barra de menus** — veja o fim da seção de primeira
  abertura em [instalacao.md](instalacao.md).
- **Toda ditada termina em "A transcrição falhou."** — falta baixar o modelo de
  voz ([instalacao.md](instalacao.md)).
- **Funcionava e parou depois de atualizar** — é a permissão de Acessibilidade
  caindo por causa da assinatura ad hoc. A correção (remover e adicionar de novo)
  está em [permissoes.md](permissoes.md).

## Privacidade

O áudio e as transcrições não saem do seu Mac. O áudio existe só na memória,
enquanto você fala. O único texto gravado em disco é o histórico, que é seu,
legível e apagável. O texto copiado pelo botão "Copiar" não é sincronizado para
os seus outros aparelhos Apple.
