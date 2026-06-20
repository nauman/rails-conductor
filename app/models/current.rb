class Current < ActiveSupport::CurrentAttributes
  attribute :user, :organization, :read_only
end
