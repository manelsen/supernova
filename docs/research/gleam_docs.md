# Gleam Documentation

**Última atualização:** 2026-03-26  
**Versão instalada:** 1.15.0  
**Fonte:** https://gleam.run/documentation/

## Links Importantes

- **Language Tour:** https://tour.gleam.run/
- **Writing Gleam:** https://gleam.run/writing-gleam
- **Standard Library:** https://hexdocs.pm/gleam_stdlib/
- **Package Index:** https://packages.gleam.run/
- **Command Line Reference:** https://gleam.run/writing-gleam/command-line-reference

## Conceitos Chave para Supernova

### 1. Type System
- Tipos estáticos com type inference
- Sum types (enums) e Product types (structs)
- Pattern matching extensivo

### 2. Actors e Concorrência
- OTP actors integrados
- Supervision trees
- Message passing

### 3. Interoperabilidade
- FFI com Erlang
- JavaScript targets
- External types

### 4. Build System
- `gleam run` - Executar projeto
- `gleam test` - Rodar testes
- `gleam build` - Compilar
- `gleam check` - Type check

## Padrões Relevantes para Channel Adapters

### Actor Pattern
```gleam
import gleam/otp/actor

pub type ChannelMessage {
  HandleInbound(reply_to: Subject(RouteResult), inbound: ChannelInbound)
}

pub fn start() -> Result(ChannelRouter, actor.StartError) {
  actor.new(initial_state)
  |> actor.on_message(handle_message)
  |> actor.start
}
```

### External Types (para FFI)
```gleam
@external(erlang, "my_module", "my_function")
fn external_function(arg: String) -> Result(String, String)
```

### Result Type para Error Handling
```gleam
pub fn route_message(msg: Message) -> RouteResult {
  case validate_message(msg) {
    Ok(valid) -> process(valid)
    Error(reason) -> Error(reason)
  }
}
```
