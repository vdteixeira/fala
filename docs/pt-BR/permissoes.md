# Permissões

O Fala precisa de duas permissões do macOS: **Microfone** e **Acessibilidade**.
Sem elas o app abre normalmente, mas não dita.

No fim desta página estão as duas armadilhas que fazem a permissão parecer
concedida quando não está. Se o atalho parou de funcionar do nada, vá direto
para elas.

## Microfone — para ouvir sua voz

O que faz: dá ao Fala acesso ao microfone enquanto você segura a tecla.

Como conceder: na primeira ditada o macOS pergunta; clique em **OK**. Se você
recusou por engano, vá em **Ajustes do Sistema › Privacidade e Segurança ›
Microfone** e ligue a chave do **Fala**.

O áudio é processado dentro do seu Mac e não é gravado em disco em momento
nenhum.

## Acessibilidade — para ver a tecla e escrever o texto

O que faz: duas coisas que o macOS agrupa nessa mesma permissão.

1. Perceber que você segurou o ⌥ direito, mesmo com outro app em foco.
2. Colar o texto no lugar onde está o seu cursor (o Fala envia um ⌘V).

É uma permissão forte, e é justo saber disso: um app com Acessibilidade pode,
em tese, observar teclas e simular digitação em qualquer aplicativo. O que o
Fala faz com ela é um monitor passivo que só observa mudanças de teclas
modificadoras e só reage ao ⌥ direito — ele não lê o que você digita —, mais o
envio do ⌘V (e do ⌘Z, para desfazer). Não existe uma permissão menor no macOS
para esse trabalho.

Como conceder:

1. **Ajustes do Sistema › Privacidade e Segurança › Acessibilidade**.
2. Clique em **+**, escolha `Aplicativos › Fala` e confirme.
3. Ligue a chave ao lado do Fala.

O menu do Fala tem um atalho: quando falta permissão, aparece uma faixa âmbar
com o botão **Conceder**, que abre o painel certo dos Ajustes.

**Depois de conceder, saia do Fala e abra de novo.** No menu do Fala, clique em
"Sair do Fala" (ou ⌘Q com o menu aberto) e abra o app outra vez. O Fala instala
o monitor de teclado só quando começa a rodar; conceder a permissão com ele já
aberto não liga o atalho.

## Armadilha 1: rodar pelo Terminal dá a permissão ao Terminal

Se você executar o Fala a partir de uma janela do Terminal, o macOS considera
que **o Terminal** é o processo responsável. A Acessibilidade é conferida contra
a permissão do Terminal, e a do Fala nunca é consultada.

O sintoma é confuso de propósito: o Fala aparece marcado na lista de
Acessibilidade, mas o atalho não faz nada, e o diagnóstico do próprio app
reporta Acessibilidade ✗.

A correção é simples: **abra o Fala pelo Finder ou pelo Launchpad**, não pelo
Terminal.

O mesmo vale para o diagnóstico: se você rodar

```
/Applications/Fala.app/Contents/MacOS/Fala doctor
```

a linha de Acessibilidade está falando do Terminal, não do Fala. As outras
linhas (microfone, atalho, modelo, dicionário) são confiáveis.

## Armadilha 2: a permissão some quando o app muda

Esta é a que custa a tarde.

A assinatura do Fala é *ad hoc*, e uma assinatura ad hoc é derivada dos próprios
bytes do programa. Qualquer versão nova é, para o macOS, **um app diferente**.
A entrada que está na lista de Acessibilidade aponta para a identidade antiga,
então a permissão deixa de valer — silenciosamente, e às vezes com a chave ainda
parecendo ligada.

Sintoma: tudo funcionava, você instalou uma versão nova, e o atalho parou.

A correção, exatamente nesta ordem:

1. **Ajustes do Sistema › Privacidade e Segurança › Acessibilidade**.
2. Selecione o **Fala** e clique no **−** para **REMOVER** a entrada.
3. Clique no **+** e adicione `Aplicativos › Fala` de novo.
4. Ligue a chave.
5. Saia do Fala e abra outra vez.

**Desmarcar e marcar de novo não resolve**, porque a entrada continua sendo a
antiga. É preciso removê-la.

Se preferir limpar pelo Terminal, isto tem o mesmo efeito do passo 2:

```
tccutil reset Accessibility com.fala.dictation
```

## Se o macOS pedir "Monitoramento de Entrada"

Em alguns Macs o sistema também lista apps que observam o teclado em **Ajustes
do Sistema › Privacidade e Segurança › Monitoramento de Entrada**. Se o Fala
aparecer lá, ligue a chave também — a lógica e as duas armadilhas acima são as
mesmas.

## O que o Fala não pede

Nenhum acesso a arquivos, contatos, fotos, gravação de tela ou rede. Se algo
assim for pedido em nome do Fala, desconfie.

## Conferir o que está concedido

Pelo app: abra o menu do Fala. Se houver algo faltando, a faixa âmbar diz o quê
("Permissões pendentes: Acessibilidade e Microfone"). Sem faixa, está tudo
concedido.

Pelo Terminal, com o aviso da armadilha 1 em mente:

```
/Applications/Fala.app/Contents/MacOS/Fala doctor
```

Ele lista permissões, a tecla de atalho, o estado do modelo de voz e o
dicionário de jargão em uso.
