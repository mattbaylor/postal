# frozen_string_literal: true

class AddDisableScanCachingToServers < ActiveRecord::Migration[7.0]
  def change
    add_column :servers, :disable_scan_caching, :boolean, default: false, after: :privacy_mode
  end
end
