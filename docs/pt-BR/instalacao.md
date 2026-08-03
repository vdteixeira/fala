# Instalar o Fala

O Fala é um app de ditado que roda inteiro no seu Mac. Este guia leva do arquivo
`.dmg` até a primeira ditada. Leve uns 10 minutos, e a maior parte é espera de
download.

## Antes de começar

- macOS 14 (Sonoma) ou mais recente.
- Mac com Apple Silicon (M1, M2, M3 ou M4). Macs com processador Intel não são
  suportados.
- Cerca de 1 GB livre no disco: o app é pequeno, mas o modelo de voz ocupa
  ~480 MB.
- Internet uma vez, só para baixar esse modelo. Depois disso o Fala funciona
  offline.

## Instalar

1. Dê dois cliques no `Fala.dmg`.
2. Arraste o **Fala** para a pasta **Aplicativos**.
3. Ejete a imagem de disco (o botão ⏏ ao lado dela no Finder).

## A primeira abertura vai ser bloqueada

Ao abrir o Fala pela primeira vez, o macOS mostra algo como:

> **"Fala" não pode ser aberto porque a Apple não pode verificar se ele contém
> software malicioso.**

E os botões oferecidos são "Mover para o Lixo" e "Cancelar" — nenhum deles abre
o app. Isso é esperado, e vale entender por quê antes de contornar.

### Por que acontece

Todo arquivo baixado da internet chega com uma marca de quarentena. Quando você
abre um app marcado assim, o macOS (Gatekeeper) confere duas coisas:

1. **Quem assinou** — um certificado Developer ID identifica o autor perante a
   Apple.
2. **Notarização** — o autor enviou o app para a Apple, que o analisou
   automaticamente em busca de malware conhecido e devolveu um carimbo.

O Fala é assinado em modo *ad hoc*. Essa assinatura garante apenas que o app não
foi alterado depois de assinado; ela **não diz quem o assinou**, e o app **não
foi notarizado**, porque o autor não tem certificado Developer ID.

Ou seja: o macOS não bloqueou porque encontrou algo errado. Ele bloqueou porque
não tem como verificar nada.

### Abrir mesmo assim

**Caminho 1 — clique com o botão direito (macOS 14):**

1. Finder › Aplicativos.
2. Clique com o botão direito (ou Control-clique) em **Fala** › **Abrir**.
3. No diálogo que aparecer, clique em **Abrir**.

**Caminho 2 — Ajustes do Sistema (funciona em todas as versões, e é o único
caminho a partir do macOS 15):**

1. Tente abrir o Fala normalmente e deixe o bloqueio aparecer.
2. Vá em **Ajustes do Sistema › Privacidade e Segurança**.
3. Role até o fim. Vai haver uma linha dizendo que o "Fala" foi bloqueado.
4. Clique em **Abrir Mesmo Assim** e confirme com Touch ID ou senha.

Só na primeira vez. O macOS passa a lembrar desta versão específica do app.
Quando você instalar uma versão nova, o processo se repete.

### O que você está aceitando ao fazer isso

Vale dizer com todas as letras: ao clicar em "Abrir Mesmo Assim" você está
assumindo a responsabilidade que normalmente seria da Apple. A verificação que
você está dispensando é real — a notarização é a varredura automática da Apple
contra malware conhecido, e ela não aconteceu com este binário.

Quem garante o app, portanto, é quem te entregou o arquivo. Algumas coisas
ajudam a decidir:

- Instale só se você conhece e confia em quem te mandou o `.dmg`, e se o arquivo
  chegou por um canal em que você confia.
- Se o autor publicou um hash do arquivo, confira antes de abrir:
  `shasum -a 256 ~/Downloads/Fala.dmg`.
- Você pode confirmar o diagnóstico sozinho, no Terminal:
  `codesign -dv --verbose=4 /Applications/Fala.app` mostra `Signature=adhoc`, e
  `spctl -a -vv /Applications/Fala.app` responde `rejected`. Isso confirma que o
  app não é notarizado; não é atestado de que ele é inofensivo.
- O Fala também pede acesso ao microfone e à Acessibilidade (veja
  [permissoes.md](permissoes.md)), e a segunda é uma permissão forte. Confiar em
  quem escreveu o app não é detalhe: é requisito.

Se você não estiver confortável com isso, não instalar é uma resposta legítima.
Distribuir uma versão assinada e notarizada é o plano — quando isso acontecer,
nada desta seção será necessário.

### Se nada aparecer na barra de menus

O Fala não tem ícone no Dock nem janela principal: quando abre, ele aparece como
um ícone de quatro barrinhas na barra de menus, no canto superior direito.

Se depois de abrir não aparecer nada lá, abra o Terminal e rode:

```
open -a Fala --args menubar
```

## A primeira ditada precisa do modelo de voz

O reconhecimento de fala roda localmente, com um modelo de ~480 MB que é baixado
uma única vez para:

```
~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3
```

Nesta versão esse download **não começa sozinho** pelo app da barra de menus.
Faça uma vez, pelo Terminal:

```
/Applications/Fala.app/Contents/MacOS/Fala listen 5
```

O comando baixa o modelo (alguns minutos, sem barra de progresso), grava 5
segundos do seu microfone e mostra a transcrição. É também o jeito mais rápido
de conferir se o microfone está funcionando.

Nesse teste o macOS vai pedir acesso ao microfone **para o Terminal** — é só
para este comando. O Fala vai pedir o dele separadamente, na primeira ditada de
verdade.

Como saber que é isso que está faltando: no menu do Fala, o bloco do modelo diz
"Modelo Parakeet · baixa no primeiro uso", e cada ditada termina com o erro
"A transcrição falhou.".

Depois do download, o menu passa a mostrar "Modelo Parakeet · pronto" e o Fala
carrega o modelo sozinho ao abrir.

## Depois de instalar

Falta conceder as duas permissões: **Microfone** e **Acessibilidade**. Elas têm
duas armadilhas que fazem perder uma tarde inteira — leia
[permissoes.md](permissoes.md) antes de sair clicando.

Para ditar, veja [uso.md](uso.md).

## Atualizar

1. Arraste a versão nova para Aplicativos, substituindo a anterior.
2. Repita o passo do Gatekeeper acima (a versão nova é bloqueada de novo).
3. **Reconceda a Acessibilidade removendo e adicionando o Fala de novo** — só
   desmarcar e marcar não resolve. O porquê está em [permissoes.md](permissoes.md).

O Fala não se atualiza sozinho e não avisa quando há versão nova.

## Desinstalar

1. Arraste `/Applications/Fala.app` para o Lixo.
2. Remova o Fala das listas em Ajustes do Sistema › Privacidade e Segurança ›
   **Microfone** e › **Acessibilidade**.
3. Se quiser apagar também os dados que ele criou:

```
~/Library/Application Support/Fala/                      histórico e dicionário
~/Library/Application Support/FluidAudio/Models/         modelo de voz (~480 MB)
~/Library/Logs/Fala/fala.log                             registro de estados
~/Library/Preferences/com.fala.dictation.plist           preferências
```

Nada disso sai do seu Mac, então apagar é só uma questão de espaço e de gosto.

## O que o Fala não faz

- Não envia áudio nem transcrições para lugar nenhum. Sem telemetria, sem conta,
  sem servidor.
- Só usa a internet para baixar o modelo, uma vez.
- Não roda em segundo plano sozinho ao ligar o Mac (ainda não há essa opção).
