//// A budget policy that never limits, for tests of gateways that are not
//// about budgets: production gateways always carry one (PRD-E, E-04).

import supernova/core/budget_policy/actor as budget_actor
import supernova/core/budget_policy/types as budget_types

pub fn unlimited() -> budget_actor.BudgetPolicy {
  let assert Ok(budget) =
    budget_actor.start_with_config(
      budget_types.BudgetConfig(
        tokens_per_hour: -1,
        tool_calls_per_minute: -1,
        tool_calls_per_hour: -1,
        max_recursion_depth: 3,
        max_sub_agents: 3,
      ),
      20,
    )
  budget
}
