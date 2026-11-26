//// A request for approval, for the channel tests (PRD-K, K-02).

import gleam/option.{None, Some}
import supernova/aprovacao/pedido
import supernova/channel/port
import supernova/self/aprovacoes.{ForTask, Pending, Request, Send}

pub fn request(id: Int) -> aprovacoes.Request {
  Request(
    id: id,
    kind: Send,
    target: "consultas.saude.gov.br",
    summary: "Usar o site consultas.saude.gov.br nesta tarefa.",
    explanation: "Para ver os horários.",
    task: Some(4),
    approve: ForTask,
    always: True,
    origin: aprovacoes.Chat("telegram", "42", "42"),
    status: Pending,
    created_at: 0,
    reminded: False,
    decided_at: None,
  )
}

/// The request as it goes out: its text and its buttons.
pub fn reply(channel_id: String, id: Int) -> port.ChannelReply {
  port.ChannelReply(
    channel_id: channel_id,
    content: pedido.message(request(id), alone: True),
    reply_to_id: None,
    thread_id: None,
    typing: False,
    edit_message_id: None,
    interactive: Some(pedido.buttons(request(id))),
    media: [],
  )
}
