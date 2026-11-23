//// A /model catalog for tests: the default provider with a second model,
//// as a boot publishes it from `models:` in supernova.yaml.

import supernova/llm/catalog
import supernova/llm/provider

pub fn with_alt_model(
  default: provider.ProviderConfig,
  alt: String,
  run: fn() -> a,
) -> a {
  catalog.set_global(
    catalog.Catalog(default: default, entries: [
      catalog.Entry(config: default, models: [default.default_model, alt]),
    ]),
  )
  let result = run()
  catalog.clear_global()
  result
}
