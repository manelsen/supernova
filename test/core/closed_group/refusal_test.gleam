import gleeunit/should
import supernova/core/closed_group/pure

pub fn kernel_refusals_are_recognized_test() {
  pure.is_kernel_refusal(pure.fail_closed_reply, "") |> should.be_true()
  pure.is_kernel_refusal(pure.rate_limited_reply, "") |> should.be_true()
  pure.is_kernel_refusal(pure.instance_cap_reply, "") |> should.be_true()
  pure.is_kernel_refusal(pure.budget_exhausted_reply(0), "")
  |> should.be_true()
  pure.is_kernel_refusal(
    " Esta instância é privada.\n",
    "Esta instância é privada.",
  )
  |> should.be_true()
}

pub fn agent_replies_are_not_refusals_test() {
  pure.is_kernel_refusal("Mock response", "Esta instância é privada.")
  |> should.be_false()
  // An empty configured denial never matches an empty reply.
  pure.is_kernel_refusal("", "") |> should.be_false()
}
