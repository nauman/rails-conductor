class AddCpuCoresToServers < ActiveRecord::Migration[8.1]
  def change
    # Static inventory, not a sample. Nullable on purpose: "we could not read it"
    # must be distinguishable from "it has zero cores".
    add_column :servers, :cpu_cores, :integer
  end
end
