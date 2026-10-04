# frozen_string_literal: true

RSpec.describe KrubyController::Reconciler do
  describe "#reconcile" do
    it "raises NotImplementedError on the base class" do
      reconciler = described_class.new

      expect { reconciler.reconcile(KrubyController::Request.new(namespace: "d", name: "n")) }
        .to raise_error(NotImplementedError, /Subclass must implement/)
    end

    it "can be implemented by a subclass" do
      reconciler = Class.new(described_class) do
        def reconcile(_request)
          KrubyController::Result.ok
        end
      end.new

      expect(reconciler.reconcile(KrubyController::Request.new(namespace: "d", name: "n")))
        .to be_a(KrubyController::Result::Ok)
    end
  end

  describe "#logger" do
    it "defaults to the global KrubyController.logger" do
      expect(described_class.new.logger).to be(KrubyController.logger)
    end

    it "can be overridden" do
      reconciler = described_class.new
      custom = Logger.new(IO::NULL)
      reconciler.logger = custom

      expect(reconciler.logger).to be(custom)
    end
  end

  describe "dependency accessors" do
    it "exposes writable cache, api_client and client" do
      reconciler = described_class.new
      cache = double("cache")
      api_client = double("api_client")
      client = double("client")

      reconciler.cache = cache
      reconciler.api_client = api_client
      reconciler.client = client

      expect(reconciler.cache).to be(cache)
      expect(reconciler.api_client).to be(api_client)
      expect(reconciler.client).to be(client)
    end
  end
end
