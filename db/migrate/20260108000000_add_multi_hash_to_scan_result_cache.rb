# frozen_string_literal: true

class AddMultiHashToScanResultCache < ActiveRecord::Migration[7.0]
  def up
    # Add new hash columns for multi-hash caching
    add_column :scan_result_cache, :attachment_hash, :string, limit: 64
    add_column :scan_result_cache, :body_template_hash, :string, limit: 64
    add_column :scan_result_cache, :matched_via, :string, limit: 20
    
    # Add composite indexes for efficient lookup with message_size
    add_index :scan_result_cache, [:attachment_hash, :message_size], 
              name: 'idx_scan_cache_attachment_hash_size'
    add_index :scan_result_cache, [:body_template_hash, :message_size], 
              name: 'idx_scan_cache_template_hash_size'
  end
  
  def down
    remove_index :scan_result_cache, name: 'idx_scan_cache_template_hash_size'
    remove_index :scan_result_cache, name: 'idx_scan_cache_attachment_hash_size'
    remove_column :scan_result_cache, :matched_via
    remove_column :scan_result_cache, :body_template_hash
    remove_column :scan_result_cache, :attachment_hash
  end
end
