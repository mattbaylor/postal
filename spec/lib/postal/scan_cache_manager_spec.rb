# frozen_string_literal: true

require "rails_helper"

describe Postal::ScanCacheManager do
  let(:raw_message) do
    <<~MESSAGE
      From: sender@example.com
      To: recipient@example.com
      Subject: Test Message
      Message-ID: <unique123@example.com>
      X-Postal-MsgID: abc123
      Date: Thu, 01 Jan 2025 12:00:00 +0000

      This is the message body.
    MESSAGE
  end

  let(:message_size) { raw_message.bytesize }

  describe ".normalize_message" do
    it "removes X-Postal-MsgID header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).not_to include("X-Postal-MsgID")
    end

    it "removes Message-ID header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).not_to include("Message-ID")
    end

    it "removes Date header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).not_to include("Date:")
    end

    it "normalizes To header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).to include("To: <normalized>")
      expect(normalized).not_to include("recipient@example.com")
    end

    it "preserves From header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).to include("From: sender@example.com")
    end

    it "preserves Subject header" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).to include("Subject: Test Message")
    end

    it "preserves message body" do
      normalized = described_class.normalize_message(raw_message)
      expect(normalized).to include("This is the message body.")
    end

    it "produces same hash for messages with different recipients" do
      message2 = raw_message.gsub("recipient@example.com", "another@example.com")
      hash1 = described_class.compute_hash(raw_message)
      hash2 = described_class.compute_hash(message2)
      expect(hash1).to eq(hash2)
    end

    it "produces different hash when subject changes" do
      message2 = raw_message.gsub("Test Message", "Different Subject")
      hash1 = described_class.compute_hash(raw_message)
      hash2 = described_class.compute_hash(message2)
      expect(hash1).not_to eq(hash2)
    end

    it "produces different hash when body changes" do
      message2 = raw_message.gsub("message body", "different content")
      hash1 = described_class.compute_hash(raw_message)
      hash2 = described_class.compute_hash(message2)
      expect(hash1).not_to eq(hash2)
    end
  end

  describe ".compute_hash" do
    it "returns a 64-character SHA-256 hex digest" do
      hash = described_class.compute_hash(raw_message)
      expect(hash).to match(/^[a-f0-9]{64}$/)
    end

    it "produces consistent hash for same message" do
      hash1 = described_class.compute_hash(raw_message)
      hash2 = described_class.compute_hash(raw_message)
      expect(hash1).to eq(hash2)
    end
  end

  describe ".caching_enabled?" do
    before do
      allow(Postal::Config.message_inspection).to receive(:cache_enabled?).and_return(true)
    end

    it "returns true when globally enabled" do
      expect(described_class.caching_enabled?).to be true
    end

    it "returns false when globally disabled" do
      allow(Postal::Config.message_inspection).to receive(:cache_enabled?).and_return(false)
      expect(described_class.caching_enabled?).to be false
    end

    context "with server_id" do
      let(:server) { create(:server, disable_scan_caching: false) }

      it "returns true when server has caching enabled" do
        expect(described_class.caching_enabled?(server.id)).to be true
      end

      it "returns false when server has caching disabled" do
        server.update(disable_scan_caching: true)
        expect(described_class.caching_enabled?(server.id)).to be false
      end
    end

    it "returns false on error" do
      allow(Postal::Config.message_inspection).to receive(:cache_enabled?).and_raise(StandardError)
      expect(described_class.caching_enabled?).to be false
    end
  end

  describe ".lookup" do
    let(:content_hash) { described_class.compute_hash(raw_message) }

    before do
      allow(Postal::Config.message_inspection).to receive(:cache_ttl_days).and_return(7)
    end

    context "when cache entry exists and is valid" do
      let!(:cache_entry) do
        ScanResultCache.create!(
          content_hash: content_hash,
          message_size: message_size,
          spam_score: 2.5,
          threat: false,
          threat_message: "No threats found",
          spam_checks_json: [].to_json,
          scanned_at: 1.day.ago
        )
      end

      it "returns the cache entry" do
        result = described_class.lookup(raw_message, message_size)
        expect(result).to eq(cache_entry)
      end
    end

    context "when cache entry is expired" do
      let!(:cache_entry) do
        ScanResultCache.create!(
          content_hash: content_hash,
          message_size: message_size,
          spam_score: 2.5,
          threat: false,
          threat_message: "No threats found",
          spam_checks_json: [].to_json,
          scanned_at: 8.days.ago
        )
      end

      it "returns nil" do
        result = described_class.lookup(raw_message, message_size)
        expect(result).to be_nil
      end
    end

    context "when cache entry does not exist" do
      it "returns nil" do
        result = described_class.lookup(raw_message, message_size)
        expect(result).to be_nil
      end
    end

    context "when message size differs (collision detection)" do
      let!(:cache_entry) do
        ScanResultCache.create!(
          content_hash: content_hash,
          message_size: message_size + 100, # Different size
          spam_score: 2.5,
          threat: false,
          threat_message: "No threats found",
          spam_checks_json: [].to_json,
          scanned_at: 1.day.ago
        )
      end

      it "returns nil (collision detected)" do
        result = described_class.lookup(raw_message, message_size)
        expect(result).to be_nil
      end
    end
  end

  describe ".store" do
    let(:inspection_result) do
      double(
        spam_score: 2.5,
        threat: false,
        threat_message: "No threats found",
        spam_checks: []
      )
    end

    before do
      allow(Postal::Config.postal).to receive(:default_spam_threshold).and_return(5.0)
    end

    it "creates a new cache entry" do
      expect do
        described_class.store(raw_message, message_size, inspection_result)
      end.to change(ScanResultCache, :count).by(1)
    end

    it "stores the correct hash" do
      described_class.store(raw_message, message_size, inspection_result)
      entry = ScanResultCache.last
      expect(entry.content_hash).to eq(described_class.compute_hash(raw_message))
    end

    it "stores the correct message size" do
      described_class.store(raw_message, message_size, inspection_result)
      entry = ScanResultCache.last
      expect(entry.message_size).to eq(message_size)
    end

    it "stores the spam score" do
      described_class.store(raw_message, message_size, inspection_result)
      entry = ScanResultCache.last
      expect(entry.spam_score).to eq(2.5)
    end

    context "when result is a threat" do
      let(:inspection_result) do
        double(
          spam_score: 2.5,
          threat: true,
          threat_message: "Virus found",
          spam_checks: []
        )
      end

      it "does not cache threats" do
        expect do
          described_class.store(raw_message, message_size, inspection_result)
        end.not_to change(ScanResultCache, :count)
      end
    end

    context "when spam score is high (near threshold)" do
      let(:inspection_result) do
        double(
          spam_score: 4.5, # > 80% of threshold (5.0)
          threat: false,
          threat_message: "No threats found",
          spam_checks: []
        )
      end

      it "does not cache high spam scores" do
        expect do
          described_class.store(raw_message, message_size, inspection_result)
        end.not_to change(ScanResultCache, :count)
      end
    end

    context "when entry already exists (race condition)" do
      before do
        ScanResultCache.create!(
          content_hash: described_class.compute_hash(raw_message),
          message_size: message_size,
          spam_score: 1.0,
          threat: false,
          threat_message: "Already cached",
          spam_checks_json: [].to_json,
          scanned_at: Time.current
        )
      end

      it "does not raise an error" do
        expect do
          described_class.store(raw_message, message_size, inspection_result)
        end.not_to raise_error
      end

      it "does not create duplicate entry" do
        expect do
          described_class.store(raw_message, message_size, inspection_result)
        end.not_to change(ScanResultCache, :count)
      end
    end
  end

  describe ".perform_maintenance" do
    before do
      allow(Postal::Config.message_inspection).to receive(:cache_ttl_days).and_return(7)
      allow(Postal::Config.message_inspection).to receive(:cache_max_entries).and_return(5)
    end

    context "with expired entries" do
      let!(:expired_entry) do
        ScanResultCache.create!(
          content_hash: "a" * 64,
          message_size: 1000,
          spam_score: 1.0,
          threat: false,
          scanned_at: 8.days.ago
        )
      end

      let!(:valid_entry) do
        ScanResultCache.create!(
          content_hash: "b" * 64,
          message_size: 1000,
          spam_score: 1.0,
          threat: false,
          scanned_at: 1.day.ago
        )
      end

      it "deletes expired entries" do
        described_class.perform_maintenance
        expect(ScanResultCache.exists?(expired_entry.id)).to be false
        expect(ScanResultCache.exists?(valid_entry.id)).to be true
      end
    end

    context "when over max entries" do
      before do
        # Create 7 entries (over max of 5)
        7.times do |i|
          ScanResultCache.create!(
            content_hash: i.to_s.rjust(64, "0"),
            message_size: 1000,
            spam_score: 1.0,
            threat: false,
            hit_count: i, # Vary hit counts for LRU
            scanned_at: i.days.ago
          )
        end
      end

      it "keeps only max_entries entries" do
        described_class.perform_maintenance
        expect(ScanResultCache.count).to eq(5)
      end

      it "keeps entries with highest hit counts" do
        described_class.perform_maintenance
        remaining_hits = ScanResultCache.pluck(:hit_count).sort
        expect(remaining_hits).to eq([2, 3, 4, 5, 6])
      end
    end
  end
end
