class RestoreWronglyDowngradedDeployTokens < ActiveRecord::Migration[8.1]
  # Repair for the org-less bug in 20260715000002: that pass compared the token's
  # bound org (nil for org-less tokens) against OperatorPolicy, so it downgraded
  # valid owner deploy tokens whose org resolves — at request time — to the user's
  # first org. Production already ran the buggy version, so those tokens now read
  # "read" and are indistinguishable from naturally read-only ones.
  #
  # Restore the precise victims: an org-less token now at "read" whose user IS an
  # operator of the resolved fallback org. Trade-off: a rare intentionally-read
  # org-less token held by an operator would also flip to deploy — low impact,
  # since that operator can mint a deploy token anyway and this only touches their
  # own token, never grants cross-tenant reach.
  def up
    ApiToken.reset_column_information
    ApiToken.where(scope: "read", organization_id: nil).find_each do |token|
      org = token.user&.organizations&.first
      token.update_columns(scope: "deploy") if OperatorPolicy.operator?(token.user, org)
    end
  end

  def down
    # One-way repair; no inverse.
  end
end
