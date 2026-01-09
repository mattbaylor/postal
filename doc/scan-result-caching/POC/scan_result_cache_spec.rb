# frozen_string_literal: true

require "rails_helper"

describe ScanResultCache do
  subject(:cache_entry) do
    described_class.new(
      content_hash: "a" * 64,
      message_size: 5000,
      spam_score: 2.5,
      threat: false,
      threat_message: "No threats found",
      spam_checks_json: sample_spam_checks_json
    )
  end

  let(:sample_spam_checks_json) do
    [
      { code: "BAYES_00", score: -1.9, description: "Bayes spam probability is 0 to 1%" },
      { code: "HTML_MESSAGE", score: 0.001, description: "HTML included in message" }
    ].to_json
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:content_hash) }
    it { is_expected.to validate_presence_of(:message_size) }
    it { is_expected.to validate_presence_of(:spam_score) }
    it { is_expected.to validate_presence_of(:scanned_at) }

    it "validates content_hash length is exactly 64 characters" do
      cache_entry.content_hash = "a" * 63
      expect(cache_entry).not_to be_valid
      expect(cache_entry.errors[:content_hash]).to include("is the wrong length (should be 64 characters)")
    end

    it "validates message_size is positive" do
      cache_entry.message_size = -1
      expect(cache_entry).not_to be_valid
      expect(cache_entry.errors[:message_size]).to include("must be greater than 0")
    end

    it "validates threat is boolean" do
      expect(cache_entry).to allow_value(true).for(:threat)
      expect(cache_entry).to allow_value(false).for(:threat)
    end
  end

  describe "callbacks" do
    it "sets scanned_at on create if not provided" do
      entry = described_class.create!(
        content_hash: "b" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false
      )
      expect(entry.scanned_at).to be_present
      expect(entry.scanned_at).to be_within(1.second).of(Time.current)
    end

    it "does not override scanned_at if provided" do
      custom_time = 2.days.ago
      entry = described_class.create!(
        content_hash: "c" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false,
        scanned_at: custom_time
      )
      expect(entry.scanned_at).to be_within(1.second).of(custom_time)
    end
  end

  describe "#spam_checks" do
    it "parses spam_checks_json into SpamCheck objects" do
      cache_entry.save!
      checks = cache_entry.spam_checks

      expect(checks).to be_an(Array)
      expect(checks.length).to eq(2)
      expect(checks.first.code).to eq("BAYES_00")
      expect(checks.first.score).to eq(-1.9)
      expect(checks.first.description).to eq("Bayes spam probability is 0 to 1%")
    end

    it "returns empty array when spam_checks_json is blank" do
      cache_entry.spam_checks_json = nil
      expect(cache_entry.spam_checks).to eq([])
    end

    it "returns empty array when spam_checks_json is invalid JSON" do
      cache_entry.spam_checks_json = "invalid json"
      expect(cache_entry.spam_checks).to eq([])
    end
  end

  describe "#spam_checks=" do
    it "serializes SpamCheck objects to JSON" do
      spam_check = Postal::MessageInspection::SpamCheck.new("TEST_CODE", 1.5, "Test description")
      cache_entry.spam_checks = [spam_check]

      expect(cache_entry.spam_checks_json).to be_present
      parsed = JSON.parse(cache_entry.spam_checks_json)
      expect(parsed.first["code"]).to eq("TEST_CODE")
      expect(parsed.first["score"]).to eq(1.5)
      expect(parsed.first["description"]).to eq("Test description")
    end
  end

  describe "#record_hit!" do
    let!(:entry) do
      described_class.create!(
        content_hash: "d" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false,
        hit_count: 5
      )
    end

    it "increments hit_count" do
      expect { entry.record_hit! }.to change { entry.reload.hit_count }.from(5).to(6)
    end

    it "updates last_hit_at timestamp" do
      Timecop.freeze do
        entry.record_hit!
        expect(entry.reload.last_hit_at).to be_within(1.second).of(Time.current)
      end
    end
  end

  describe "#valid_cache_entry?" do
    let(:entry) do
      described_class.new(
        content_hash: "e" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false,
        scanned_at: scan_time
      )
    end

    context "when entry is within TTL" do
      let(:scan_time) { 3.days.ago }

      it "returns true" do
        expect(entry.valid_cache_entry?(7)).to be true
      end
    end

    context "when entry is at TTL boundary" do
      let(:scan_time) { 7.days.ago }

      it "returns false" do
        expect(entry.valid_cache_entry?(7)).to be false
      end
    end

    context "when entry is beyond TTL" do
      let(:scan_time) { 10.days.ago }

      it "returns false" do
        expect(entry.valid_cache_entry?(7)).to be false
      end
    end
  end

  describe "database constraints" do
    let!(:existing_entry) do
      described_class.create!(
        content_hash: "f" * 64,
        message_size: 1000,
        spam_score: 1.0,
        threat: false
      )
    end

    it "enforces unique constraint on content_hash + message_size" do
      duplicate = described_class.new(
        content_hash: existing_entry.content_hash,
        message_size: existing_entry.message_size,
        spam_score: 2.0,
        threat: false
      )

      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows same hash with different size" do
      different_size = described_class.new(
        content_hash: existing_entry.content_hash,
        message_size: 2000, # Different size
        spam_score: 2.0,
        threat: false
      )

      expect { different_size.save! }.not_to raise_error
    end
  end
end
