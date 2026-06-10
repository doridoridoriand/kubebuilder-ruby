# frozen_string_literal: true

module KrubyController
  class Reconciler
    def reconcile(request)
      raise NotImplementedError, "Subclass must implement reconcile(request)"
    end

    attr_writer :logger
    def logger
      @logger || KrubyController.logger
    end

    attr_accessor :cache
    attr_accessor :api_client
    attr_accessor :client
  end
end
