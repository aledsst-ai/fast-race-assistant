# FAST Race Assistant

Auxiliar oficial de colagem sequencial da FAST Division, produzido por
**Fael Verstappen**.

O programa mantém o método simples de Ctrl+C e Ctrl+V: o site prepara os campos
do anúncio e o auxiliar entrega cada conteúdo na ordem certa conforme o membro
pressiona Ctrl+V. O registro de corridas continua sendo feito manualmente no
portal FAST.

## Download

[Baixar a versão mais recente](https://github.com/aledsst-ai/fast-race-assistant/releases/latest/download/fast-race-assistant.zip)

Depois de extrair o ZIP, execute `iniciar-fast-race-assistant.cmd`. O Windows
pode exibir o aviso **Editor desconhecido** porque o programa ainda não possui
assinatura digital comercial.

## Como usar

1. No portal FAST, prepare a sequência do anúncio.
2. Deixe o auxiliar aberto na bandeja do Windows.
3. Pressione Ctrl+V para colar, em ordem, título, mensagem, duração e imagem
   opcional.

O auxiliar não observa a tela, não faz OCR, não captura comprovantes e não
envia resultados de corrida.

## Atualizações automáticas

O aplicativo consulta o manifesto da última GitHub Release ao iniciar.
Uma versão baixada é validada por SHA-256 e aplicada na próxima inicialização.

Cada alteração funcional deve aumentar a versão em `app/version.json`. Um
push na branch `main` gera o pacote, executa a verificação do aplicativo e cria
automaticamente a Release `vX.Y.Z` com o ZIP e o manifesto de integridade.

## Requisitos

- Windows 10 ou 11;
- Windows PowerShell 5.1;
- acesso à internet apenas para receber atualizações automáticas.

## Privacidade

O programa não observa nem captura a tela. Ele trabalha somente com a sequência
de colagem copiada pelo próprio membro no portal.

Copyright © 2026 Fael Verstappen. Todos os direitos reservados.
