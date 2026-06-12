# frozen_string_literal: true

module KrubyController
  module Election
    class LeaderElector
      attr_reader :leader

      def initialize(client:, lease_name:, lease_namespace:,
                     lease_duration: 15, renew_deadline: 10,
                     retry_period: 2, identity: nil)
        @client = client
        @lease_name = lease_name
        @lease_namespace = lease_namespace
        @lease_duration = lease_duration
        @renew_deadline = renew_deadline
        @retry_period = retry_period
        @identity = identity || "#{Socket.gethostname}-#{Process.pid}"
        @leader = false
        @running = false
      end

      def run(&block)
        @running = true
        @block = block
        @thread = Thread.new { election_loop }
      end

      def stop
        @running = false
        @thread&.join
      end

      private

      def election_loop
        while @running
          if try_acquire
            @leader = true
            @block.call if @block
            renewal_loop
          else
            sleep @retry_period
          end
        end
      end

      def try_acquire
        # TODO: implement Lease API acquire
        true
      end

      def renewal_loop
        while @running && @leader
          sleep @retry_period
        end
        @leader = false
      end
    end
  end
end
