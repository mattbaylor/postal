# frozen_string_literal: true

class RemoveScanResultCache < ActiveRecord::Migration[7.0]
  def up
    drop_table :scan_result_cache if table_exists?(:scan_result_cache)
    
    if column_exists?(:servers, :disable_scan_caching)
      remove_column :servers, :disable_scan_caching
    end
  end
  
  def down
    raise ActiveRecord::IrreversibleMigration, "Removing scan result cache feature - not reversible"
  end
end
