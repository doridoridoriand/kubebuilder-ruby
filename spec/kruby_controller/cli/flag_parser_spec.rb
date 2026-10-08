# frozen_string_literal: true

RSpec.describe KrubyController::CLI::FlagParser do
  describe ".dns_label?" do
    it "accepts a valid DNS label" do
      expect(described_class.dns_label?("crontasks")).to be(true)
      expect(described_class.dns_label?("a-b-1")).to be(true)
    end

    it "rejects underscores, uppercase, leading/trailing dashes, and >63 chars" do
      expect(described_class.dns_label?("cron_task")).to be(false)
      expect(described_class.dns_label?("CronTask")).to be(false)
      expect(described_class.dns_label?("-abc")).to be(false)
      expect(described_class.dns_label?("abc-")).to be(false)
      expect(described_class.dns_label?("a" * 64)).to be(false)
    end
  end

  describe ".dns_subdomain?" do
    it "accepts a valid DNS subdomain" do
      expect(described_class.dns_subdomain?("stable.example.com")).to be(true)
      expect(described_class.dns_subdomain?("example.com")).to be(true)
    end

    it "rejects a trailing dot (empty final label)" do
      expect(described_class.dns_subdomain?("example.com.")).to be(false)
    end

    it "rejects a leading dot (empty first label)" do
      expect(described_class.dns_subdomain?(".example.com")).to be(false)
    end

    it "rejects an internal empty label" do
      expect(described_class.dns_subdomain?("example..com")).to be(false)
    end

    it "rejects values over the 253-character subdomain limit" do
      # 4 labels of 63 chars + 3 dots = 255 chars > 253 (each label is valid)
      expect(described_class.dns_subdomain?(Array.new(4) { "a" * 63 }.join("."))).to be(false)
    end

    it "rejects non-DNS labels" do
      expect(described_class.dns_subdomain?("corp_internal")).to be(false)
      expect(described_class.dns_subdomain?("")).to be(false)
    end
  end

  describe ".normalize_dns_label" do
    it "strips a .git suffix and lowercases" do
      expect(described_class.normalize_dns_label("Widget.Repo.git")).to eq("widget-repo")
    end

    it "collapses invalid characters and trims to 63 chars" do
      expect(described_class.normalize_dns_label("my_repo")).to eq("my-repo")
      expect(described_class.normalize_dns_label("a" * 80)).to eq("a" * 63)
    end

    it "returns nil when nothing valid remains" do
      expect(described_class.normalize_dns_label("...")).to be_nil
    end
  end
end
