import supernova/core/executor
import supernova/llm/provider

pub fn friendly(error: executor.ExecutorError) -> String {
  case error {
    executor.MaxDepthExceeded(_) ->
      "A tarefa ficou complexa demais para completar em uma unica execucao. Tente dividir em partes menores ou use /reset."
    executor.LLMError(reason) -> friendly_llm(reason)
    executor.ToolError(name, reason) ->
      "A ferramenta '" <> name <> "' encontrou um problema: " <> reason
    executor.YieldAborted(reason) -> "A execucao foi interrompida: " <> reason
    executor.YieldPaused(checkpoint_id) ->
      "A execucao foi pausada temporariamente (checkpoint "
      <> checkpoint_id
      <> ")."
    executor.PolicyDenied(message) -> message
  }
}

fn friendly_llm(error: provider.LLMError) -> String {
  case error {
    provider.APIError(status, _) if status == 429 ->
      "O provedor de IA esta sobrecarregado agora. Aguarde alguns instantes e tente novamente."
    provider.APIError(status, _) if status == 401 ->
      "Credenciais do provedor de IA invalidas ou expiradas. Verifique a configuracao."
    provider.NetworkError(_) ->
      "Nao foi possivel alcancar o provedor de IA. Verifique a conexao e tente novamente."
    provider.CircuitOpen(_) ->
      "O provedor de IA esta temporariamente indisponivel. Tentando recuperacao automatica."
    provider.APIError(_, message) ->
      "O provedor de IA retornou um erro: " <> message
    provider.ConfigError(reason) ->
      "A configuracao do provedor de IA esta invalida: " <> reason
    provider.ProviderNotFound(name) -> "Provedor de IA nao encontrado: " <> name
    provider.NotImplemented(reason) ->
      "Esse recurso ainda nao esta disponivel neste provedor: " <> reason
  }
}
