# FAST Race Assistant

Assistente oficial de corridas da FAST Division para FiveM, produzido por
**Fael Verstappen**.

O programa identifica o cartão de finalização, lê a corrida, a colocação e o
tempo total, e envia ao portal somente quando o resultado supera o recorde
pessoal do membro. A captura da tela é mantida como comprovante do registro.

## Download

[Baixar a versão mais recente](https://github.com/aledsst-ai/fast-race-assistant/releases/latest/download/fast-race-assistant.zip)

Depois de extrair o ZIP, execute `iniciar-fast-race-assistant.cmd`. O Windows
pode exibir o aviso **Editor desconhecido** porque o programa ainda não possui
assinatura digital comercial.

## Atualizações automáticas

O aplicativo consulta o manifesto da última GitHub Release a cada seis horas.
Uma versão baixada é validada por SHA-256 e aplicada na próxima inicialização.

Cada alteração funcional deve aumentar a versão em `app/version.json`. Um
push na branch `main` gera o pacote, executa a verificação do aplicativo e cria
automaticamente a Release `vX.Y.Z` com o ZIP e o manifesto de integridade.

## Requisitos

- Windows 10 ou 11;
- Windows PowerShell 5.1;
- resolução de 1920 × 1080 ou superior;
- acesso à internet e vínculo individual com o Discord pelo portal FAST.

## Privacidade

O programa observa somente a janela ativa do FiveM. Capturas contínuas não são
enviadas; apenas a imagem em que o cartão de conclusão é confirmado pode ser
usada como comprovante.

Copyright © 2026 Fael Verstappen. Todos os direitos reservados.
