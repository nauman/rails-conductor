class FailClosedOrgLessOperatorTokens < ActiveRecord::Migration[8.1]
  # Fail-closed cleanup for the org-less token saga (20260715000002 downgrade bug
  # + 20260715000004 unsafe promotion, now neutralized).
  #
  # Any org-less deploy token whose user is an operator is ambiguous: it may be a
  # bug victim OR a token 20260715000004 wrongly promoted OR one legitimately
  # minted deploy — the data can't tell them apart. The only safe resolution is
  # to fail closed: drop them all to read. Owners who need write re-mint an
  # org-bound deploy token (the mcp_tokens flow always binds an org), which is
  # the auditable recovery path. Downgrading only ever removes capability, so it
  # can't open a hole. Org-BOUND tokens are untouched.
  def up
    ApiToken.reset_column_information
    ApiToken.where(scope: "deploy", organization_id: nil).find_each do |token|
      org = token.user&.organizations&.first
      token.update_columns(scope: "read") if OperatorPolicy.operator?(token.user, org)
    end
  end

  def down
    # One-way fail-closed cleanup; no inverse.
  end
end
