class AddSwapReclaimTrackingToServers < ActiveRecord::Migration[8.0]
  def change
    add_column :servers, :last_swap_reclaim_status, :string
    add_column :servers, :last_swap_reclaim_log, :text
    add_column :servers, :last_swap_reclaim_at, :datetime
  end
end
