# frozen_string_literal: true

# ActiveRecord model for the scan_result_cache table
# Stores cached results of spam/virus scans based on message content hash
class ScanResultCache < ApplicationRecord
  self.table_name = "scan_result_cache"

  # Validations
  validates :content_hash, presence: true, length: { is: 64 }
  validates :message_size, presence: true, numericality: { greater_than: 0 }
  validates :spam_score, presence: true, numericality: true
  validates :threat, inclusion: { in: [true, false] }
  validates :scanned_at, presence: true

  # Callbacks
  before_validation :set_scanned_at, on: :create

  # Parse spam_checks JSON into array of SpamCheck objects
  def spam_checks
    return [] if spam_checks_json.blank?

    JSON.parse(spam_checks_json).map do |check|
      Postal::MessageInspection::SpamCheck.new(
        check["code"],
        check["score"].to_f,
        check["description"]
      )
    end
  rescue JSON::ParserError
    []
  end

  # Set spam_checks from array of SpamCheck objects
  def spam_checks=(checks)
    self.spam_checks_json = checks.map do |check|
      {
        code: check.code,
        score: check.score,
        description: check.description
      }
    end.to_json
  end

  # Record a cache hit
  def record_hit!
    increment!(:hit_count)
    touch(:last_hit_at)
  end

  # Check if cache entry is still valid (not expired)
  def valid_cache_entry?(ttl_days)
    scanned_at > ttl_days.days.ago
  end

  private

  def set_scanned_at
    self.scanned_at ||= Time.current
  end
end
