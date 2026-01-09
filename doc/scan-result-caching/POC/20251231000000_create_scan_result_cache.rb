# frozen_string_literal: true

class CreateScanResultCache < ActiveRecord::Migration[7.0]
  def change
    create_table :scan_result_cache, charset: "utf8mb4", collation: "utf8mb4_general_ci" do |t|
      # Content identification
      t.string :content_hash, limit: 64, null: false # SHA-256 hash (64 hex chars)
      t.integer :message_size, null: false           # Original message size for collision detection

      # Scan results (copied from MessageInspection)
      t.decimal :spam_score, precision: 8, scale: 2, null: false, default: 0.0
      t.boolean :threat, null: false, default: false
      t.string :threat_message, limit: 500
      t.text :spam_checks_json                       # JSON array of spam checks

      # Cache metadata
      t.datetime :scanned_at, precision: nil, null: false
      t.integer :hit_count, null: false, default: 0
      t.datetime :last_hit_at, precision: nil

      t.timestamps precision: nil
    end

    # Primary lookup index: must be unique
    add_index :scan_result_cache, [:content_hash, :message_size], 
              unique: true, 
              name: "index_scan_cache_on_hash_and_size"

    # Maintenance indexes
    add_index :scan_result_cache, :scanned_at, name: "index_scan_cache_on_scanned_at"
    add_index :scan_result_cache, :hit_count, name: "index_scan_cache_on_hit_count"
  end
end
