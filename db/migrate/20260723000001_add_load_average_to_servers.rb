class AddLoadAverageToServers < ActiveRecord::Migration[8.1]
  def change
    # 1-minute load average, captured alongside the other stored metrics so the
    # MCP fleet payload (and the situation read) can report it without a live probe.
    add_column :servers, :load_average, :decimal, precision: 6, scale: 2
  end
end
