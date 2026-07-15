class DowngradeNonOperatorDeployTokens < ActiveRecord::Migration[8.1]
  # Any existing deploy-scoped token whose user is not an org owner/admin could
  # mutate infrastructure before the OperatorPolicy gate. Downgrade them to read
  # (the runtime gate now blocks them anyway — this is cleanup/defense in depth).
  def up
    ApiToken.reset_column_information
    ApiToken.where(scope: "deploy").find_each do |token|
      # Resolve the SAME org Api::BaseController uses at request time: a token
      # with no bound org falls back to the user's first org. (The original
      # version passed token.organization — nil here — and wrongly downgraded
      # valid owner tokens; migration 20260715000004 repairs those.)
      org = token.organization || token.user&.organizations&.first
      next if OperatorPolicy.operator?(token.user, org)

      token.update_columns(scope: "read")
    end
  end

  def down
    # One-way: we don't restore downgraded scopes.
  end
end
