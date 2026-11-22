# Referências de API dos canais

Notas sobre a API externa de cada canal, reunidas em março de 2026, quando os adaptadores foram escritos. São retratos daquele momento: confira a documentação oficial antes de confiar num detalhe.

| Canal | Notas | Situação na Supernova |
|---|---|---|
| Telegram | `telegram_api.md` | Suportado (grupo fechado completo) |
| Discord | `discord_api.md` | Suportado; paridade com o Telegram decidida em 22/11 |
| Slack | `slack_api.md` | Adaptador nativo, experimental |
| Matrix | `matrix_api.md`, `ADAPTERS_API.md` | Adaptador nativo, experimental |
| WhatsApp (bridge) | `ADAPTERS_API.md` | Adaptador nativo, experimental |
| Mattermost | `mattermost_api.md`, `ADAPTERS_API.md` | Adaptador nativo, experimental |
| Google Chat | `google_chat_api.md` | Adaptador nativo, experimental |
| Lark/Feishu | `lark_api.md` | Adaptador nativo, experimental |
| WeChat Work | `wechat_work_api.md` | Adaptador nativo, experimental |
| QQ | `qq_api.md` | Sem adaptador |

"Experimental" quer dizer que o canal ainda não passa pelo grupo fechado (acesso, orçamento, comandos) nem tem testes de ponta a ponta. A ordem dos próximos canais está em [`docs/PENDENCIAS.md`](../PENDENCIAS.md), seção 3.2.

Ao acrescentar notas de um canal, registre:

- **Auth:** como autenticar (token, OAuth etc.).
- **Endpoints principais:** enviar, receber, threading.
- **Estrutura das mensagens.**
- **Rate limits.**
- **Eventos:** WebSocket ou webhook.
- **Elementos interativos:** botões, menus.
