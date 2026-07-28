# Spec 07, slice 1. Why a deploy failed, coarsely — so the UI can say "not your code".
#
# Two of one week's failures were Conductor's own bugs (a shared buildx builder pointing
# at another app's host; an ssh config stanza naming a deleted key). Rendering those the
# same as a broken migration sends people to debug the wrong thing.
class AddCauseClassToDeployments < ActiveRecord::Migration[8.1]
  def change
    add_column :deployments, :cause_class, :string
  end
end
