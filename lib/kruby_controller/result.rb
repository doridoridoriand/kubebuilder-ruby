# frozen_string_literal: true

module KrubyController
  module Result
    class Base
      attr_reader :error
      def initialize(error: nil)
        @error = error
      end
    end

    class Ok < Base
      def self.ok(error: nil)
        new(error:)
      end
    end

    class RetryAfter < Base
      attr_reader :after

      def initialize(after:, error: nil)
        raise ArgumentError, "after must be positive" unless after > 0
        @after = after
        super(error:)
      end

      def self.retry_after(seconds, error: nil)
        new(after: seconds, error:)
      end
    end

    class Requeue < Base
      def self.requeue(error: nil)
        new(error:)
      end
    end

    def self.ok(error: nil)
      Ok.ok(error:)
    end

    def self.retry_after(seconds, error: nil)
      RetryAfter.retry_after(seconds, error:)
    end

    def self.requeue(error: nil)
      Requeue.requeue(error:)
    end
  end
end
