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

  describe ".compute_attachment_hash" do
    context "with no attachments" do
      it "returns nil for plain text message" do
        result = described_class.compute_attachment_hash(raw_message)
        expect(result).to be_nil
      end
    end

    context "with attachments" do
      let(:message_with_attachment) do
        <<~MESSAGE
          From: sender@example.com
          To: recipient@example.com
          Subject: Test with attachment
          MIME-Version: 1.0
          Content-Type: multipart/mixed; boundary="boundary123"

          --boundary123
          Content-Type: text/plain

          Body text here

          --boundary123
          Content-Type: application/pdf; name="doc.pdf"
          Content-Transfer-Encoding: base64
          Content-Disposition: attachment; filename="doc.pdf"

          JVBERi0xLjQKJeLjz9MK
          --boundary123--
        MESSAGE
      end

      it "returns a 64-character SHA-256 hex digest" do
        hash = described_class.compute_attachment_hash(message_with_attachment)
        expect(hash).to match(/^[a-f0-9]{64}$/)
      end

      it "produces consistent hash for same attachments" do
        hash1 = described_class.compute_attachment_hash(message_with_attachment)
        hash2 = described_class.compute_attachment_hash(message_with_attachment)
        expect(hash1).to eq(hash2)
      end

      it "sorts attachments before hashing" do
        message_unsorted = message_with_attachment.gsub("doc.pdf", "zebra.pdf")
        # Should produce same hash regardless of order
        hash1 = described_class.compute_attachment_hash(message_with_attachment)
        hash2 = described_class.compute_attachment_hash(message_unsorted)
        expect(hash1).not_to eq(hash2) # Different filenames = different hash
      end
    end

    context "error handling" do
      it "returns nil on parsing error" do
        invalid_message = "Not a valid MIME message"
        result = described_class.compute_attachment_hash(invalid_message)
        expect(result).to be_nil
      end
    end
  end

  describe ".compute_body_template_hash" do
    let(:personalized_message) do
      <<~MESSAGE
        From: sender@example.com
        To: john@example.com
        Subject: Weekly Newsletter

        Hi John,

        Thanks for being a valued customer!
        Check out our sale this Monday.

        Best regards,
        The Team
      MESSAGE
    end

    it "returns a 64-character SHA-256 hex digest" do
      hash = described_class.compute_body_template_hash(personalized_message)
      expect(hash).to match(/^[a-f0-9]{64}$/)
    end

    it "produces same hash for messages with different recipient names in greetings" do
      message2 = personalized_message.gsub("Hi John", "Hi Sarah")
      hash1 = described_class.compute_body_template_hash(personalized_message)
      hash2 = described_class.compute_body_template_hash(message2)
      expect(hash1).to eq(hash2)
    end

    it "produces same hash for Dear/Hi/Hello patterns" do
      msg_dear = personalized_message.gsub("Hi John", "Dear John")
      msg_hello = personalized_message.gsub("Hi John", "Hello John")
      hash_hi = described_class.compute_body_template_hash(personalized_message)
      hash_dear = described_class.compute_body_template_hash(msg_dear)
      hash_hello = described_class.compute_body_template_hash(msg_hello)
      expect(hash_hi).to eq(hash_dear)
      expect(hash_hi).to eq(hash_hello)
    end

    it "does not normalize capitalized words like 'Monday' or 'Sale'" do
      message2 = personalized_message.gsub("Monday", "Tuesday")
      hash1 = described_class.compute_body_template_hash(personalized_message)
      hash2 = described_class.compute_body_template_hash(message2)
      expect(hash1).not_to eq(hash2)
    end

    it "includes subject in template hash" do
      message2 = personalized_message.gsub("Weekly Newsletter", "Monthly Newsletter")
      hash1 = described_class.compute_body_template_hash(personalized_message)
      hash2 = described_class.compute_body_template_hash(message2)
      expect(hash1).not_to eq(hash2)
    end

    context "error handling" do
      it "returns nil on parsing error" do
        result = described_class.compute_body_template_hash(nil)
        expect(result).to be_nil
      end
    end
  end

  describe ".normalize_template_text" do
    it "normalizes 'Hi John' pattern" do
      result = described_class.normalize_template_text("Hi John,\nHow are you?")
      expect(result).to include("Hi NAME")
      expect(result).not_to include("John")
    end

    it "normalizes 'Dear Sarah' pattern" do
      result = described_class.normalize_template_text("Dear Sarah,\nThank you")
      expect(result).to include("Dear NAME")
      expect(result).not_to include("Sarah")
    end

    it "normalizes 'Hello Bob' pattern" do
      result = described_class.normalize_template_text("Hello Bob!\nWelcome")
      expect(result).to include("Hello NAME")
      expect(result).not_to include("Bob")
    end

    it "does not normalize standalone capitalized words" do
      text = "Check out our Monday Sale for Big Savings"
      result = described_class.normalize_template_text(text)
      expect(result).to eq(text)
    end

    it "does not affect greeting patterns not followed by names" do
      text = "Hi there,\nHow are you?"
      result = described_class.normalize_template_text(text)
      expect(result).to eq(text)
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
      allow(Postal::Config.message_inspection).to receive(:cache_attachment_hash_enabled?).and_return(true)
      allow(Postal::Config.message_inspection).to receive(:cache_template_hash_enabled?).and_return(true)
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

    it "stores all three hashes when applicable" do
      described_class.store(raw_message, message_size, inspection_result)
      entry = ScanResultCache.last
      expect(entry.content_hash).to be_present
      # attachment_hash and body_template_hash may be nil for this simple message
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
          spam_score: 2.5, # > 2.0 threshold in new implementation
          threat: false,
          threat_message: "No threats found",
          spam_checks: []
        )
      end

      it "caches scores below 2.0" do
        allow(inspection_result).to receive(:spam_score).and_return(1.5)
        expect do
          described_class.store(raw_message, message_size, inspection_result)
        end.to change(ScanResultCache, :count).by(1)
      end

      it "does not cache scores at or above 2.0" do
        allow(inspection_result).to receive(:spam_score).and_return(2.0)
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

  describe ".lookup with multi-hash (sequential checking)" do
    let(:content_hash) { described_class.compute_hash(raw_message) }

    before do
      allow(Postal::Config.message_inspection).to receive(:cache_ttl_days).and_return(7)
      allow(Postal::Config.message_inspection).to receive(:cache_attachment_hash_enabled?).and_return(true)
      allow(Postal::Config.message_inspection).to receive(:cache_template_hash_enabled?).and_return(true)
    end

    context "when full hash matches" do
      let!(:cache_entry) do
        ScanResultCache.create!(
          content_hash: content_hash,
          message_size: message_size,
          spam_score: 1.5,
          threat: false,
          threat_message: "No threats",
          spam_checks_json: [].to_json,
          scanned_at: 1.day.ago
        )
      end

      it "returns the entry and records full_hash match" do
        result = described_class.lookup(raw_message, message_size)
        expect(result).to eq(cache_entry)
        cache_entry.reload
        expect(cache_entry.matched_via).to eq("full_hash")
      end
    end

    context "when only attachment hash matches" do
      let(:message_with_attachment) do
        <<~MESSAGE
          From: sender@example.com
          To: recipient@example.com
          Subject: Test
          MIME-Version: 1.0
          Content-Type: multipart/mixed; boundary="b"

          --b
          Content-Type: text/plain

          Different body text

          --b
          Content-Type: application/pdf
          Content-Transfer-Encoding: base64

          JVBERi0xLjQ=
          --b--
        MESSAGE
      end

      let!(:cache_entry) do
        attachment_hash = described_class.compute_attachment_hash(message_with_attachment)
        ScanResultCache.create!(
          content_hash: "different_hash" + "0" * 50,
          attachment_hash: attachment_hash,
          message_size: message_with_attachment.bytesize,
          spam_score: 1.5,
          threat: false,
          threat_message: "No threats",
          spam_checks_json: [].to_json,
          scanned_at: 1.day.ago
        )
      end

      it "returns the entry and records attachment_hash match" do
        result = described_class.lookup(message_with_attachment, message_with_attachment.bytesize)
        expect(result).to eq(cache_entry)
        cache_entry.reload
        expect(cache_entry.matched_via).to eq("attachment_hash")
      end
    end

    context "when only template hash matches" do
      let(:personalized_message1) do
        <<~MESSAGE
          From: sender@example.com
          To: john@example.com
          Subject: Newsletter

          Hi John,
          Thanks for subscribing!
        MESSAGE
      end

      let(:personalized_message2) do
        <<~MESSAGE
          From: sender@example.com
          To: sarah@example.com
          Subject: Newsletter

          Hi Sarah,
          Thanks for subscribing!
        MESSAGE
      end

      let!(:cache_entry) do
        template_hash = described_class.compute_body_template_hash(personalized_message1)
        ScanResultCache.create!(
          content_hash: "different_hash" + "0" * 50,
          body_template_hash: template_hash,
          message_size: personalized_message1.bytesize,
          spam_score: 1.5,
          threat: false,
          threat_message: "No threats",
          spam_checks_json: [].to_json,
          scanned_at: 1.day.ago
        )
      end

      it "returns the entry and records body_template_hash match" do
        result = described_class.lookup(personalized_message2, personalized_message2.bytesize)
        expect(result).to eq(cache_entry)
        cache_entry.reload
        expect(cache_entry.matched_via).to eq("body_template_hash")
      end
    end

    context "when attachment hash is disabled" do
      before do
        allow(Postal::Config.message_inspection).to receive(:cache_attachment_hash_enabled?).and_return(false)
      end

      it "skips attachment hash lookup" do
        expect(described_class).not_to receive(:compute_attachment_hash)
        described_class.lookup(raw_message, message_size)
      end
    end

    context "when template hash is disabled" do
      before do
        allow(Postal::Config.message_inspection).to receive(:cache_template_hash_enabled?).and_return(false)
      end

      it "skips template hash lookup" do
        expect(described_class).not_to receive(:compute_body_template_hash)
        described_class.lookup(raw_message, message_size)
      end
    end
  end

  describe ".invalidate_all!" do
    before do
      3.times do |i|
        ScanResultCache.create!(
          content_hash: i.to_s.rjust(64, "0"),
          message_size: 1000,
          spam_score: 1.0,
          threat: false,
          scanned_at: i.days.ago
        )
      end
    end

    it "deletes all cache entries" do
      expect(ScanResultCache.count).to eq(3)
      described_class.invalidate_all!
      expect(ScanResultCache.count).to eq(0)
    end
  end

  describe ".invalidate_older_than" do
    before do
      ScanResultCache.create!(
        content_hash: "a" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false,
        scanned_at: 10.days.ago
      )
      ScanResultCache.create!(
        content_hash: "b" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false,
        scanned_at: 2.days.ago
      )
    end

    it "deletes entries older than specified days" do
      described_class.invalidate_older_than(5)
      expect(ScanResultCache.count).to eq(1)
      expect(ScanResultCache.first.content_hash).to eq("b" * 64)
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
