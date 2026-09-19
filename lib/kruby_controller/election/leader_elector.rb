# frozen_string_literal: true

require "time"

module KrubyController
  module Election
    # Lease-based leader election using the coordination.k8s.io/v1 Lease API.
    #
    #   elector = LeaderElector.new(
    #     client: coordination_api,
    #     lease_name: "my-controller-lock",
    #     lease_namespace: "kube-system"
    #   )
    #   elector.run { start_controllers }
    #
    # While leading, the lease is renewed every retry_period. When leadership
    # is lost (lease taken over by another identity), the renewal stops and
    # on_stopped_leading is invoked; the elector then keeps retrying.
    class LeaderElector
      attr_reader :leader

      def initialize(
        client:,
        lease_name:,
        lease_namespace:,
        lease_duration: 15,
        renew_deadline: 10,
        retry_period: 2,
        identity: nil,
        on_stopped_leading: nil
      )
        @client = client
        @lease_name = lease_name
        @lease_namespace = lease_namespace
        @lease_duration = lease_duration
        @renew_deadline = renew_deadline
        @retry_period = retry_period
        @identity = identity || "#{Socket.gethostname}-#{Process.pid}"
        @on_stopped_leading = on_stopped_leading
        @leader = false
        @running = false
        @renewal_running = false
        @thread = nil
        @started_leading_block = nil
      end

      def run(&block)
        @started_leading_block = block || nil
        @running = true
        @thread = Thread.new { election_loop }
        self
      end

      def stop
        @running = false
        @renewal_running = false
        @thread&.join
      end

      private

      def election_loop
        begin
          while @running
            unless try_acquire
              sleep @retry_period
              next
            end

            @leader = true
            @renewal_running = true
            renewal_thread = Thread.new { renewal_loop }
            begin
              @started_leading_block&.call
            rescue => e
              KrubyController.logger.error("LeaderElector: on_started_leading failed: #{e.message}")
            end
            renewal_thread.join
            @renewal_running = false
            @leader = false
            @on_stopped_leading&.call
            sleep @retry_period
          end
        ensure
          release
        end
      end

      def try_acquire
        lease = get_or_create_lease
        return false unless lease_can_be_acquired?(lease)

        update_lease(lease)
        true
      rescue Kubernetes::ApiError => e
        KrubyController.logger.warn("LeaderElector: acquire failed (HTTP #{e.code}): #{e.message}")
        false
      end

      def renewal_loop
        @last_successful_renewal = Time.now
        while @running && @renewal_running
          if renew_lease
            @last_successful_renewal = Time.now
          elsif lost_leadership?
            KrubyController.logger.warn("LeaderElector: lost leadership")
            @leader = false
            break
          elsif renewal_deadline_exceeded?
            KrubyController.logger.warn("LeaderElector: renew deadline exceeded, stepping down")
            @leader = false
            break
          end
          sleep @retry_period
        end
      end

      def renewal_deadline_exceeded?
        (Time.now - @last_successful_renewal) > @renew_deadline
      end

      def renew_lease
        lease = get_or_create_lease
        return false unless lease_can_be_acquired?(lease)

        update_lease(lease)
        true
      rescue Kubernetes::ApiError => e
        KrubyController.logger.warn("LeaderElector: renewal failed (HTTP #{e.code}): #{e.message}")
        false
      end

      def lost_leadership?
        lease = read_lease
        holder = lease&.spec&.holder_identity
        !holder.nil? && !holder.empty? && holder != @identity
      rescue Kubernetes::ApiError
        false
      end

      def get_or_create_lease
        read_lease
      rescue Kubernetes::ApiError => e
        raise unless e.code == 404

        create_lease
      end

      def read_lease
        @client.read_namespaced_lease(@lease_name, @lease_namespace)
      end

      def create_lease
        body = Kubernetes::V1Lease.build_from_hash(
          metadata: { name: @lease_name, namespace: @lease_namespace },
          spec: { leaseDurationSeconds: @lease_duration }
        )
        @client.create_namespaced_lease(@lease_namespace, body)
      end

      def lease_can_be_acquired?(lease)
        spec = lease.spec
        return true if spec.nil? || spec.holder_identity.nil? || spec.holder_identity.empty?
        return true if spec.holder_identity == @identity

        last_seen = to_time(spec.renew_time) || to_time(spec.acquire_time)
        return false if last_seen.nil?

        (Time.now - last_seen) > (spec.lease_duration_seconds || @lease_duration)
      end

      def update_lease(lease)
        spec = lease.spec || Kubernetes::V1LeaseSpec.new
        now = Time.now.utc
        spec.acquire_time = now if spec.holder_identity.nil? || spec.holder_identity != @identity
        spec.holder_identity = @identity
        spec.lease_duration_seconds = @lease_duration
        spec.renew_time = now
        lease.spec = spec
        @client.replace_namespaced_lease(@lease_name, @lease_namespace, lease)
        true
      end

      # Clears the holder using the resourceVersion read above as an atomic
      # precondition, so a takeover between read and release fails with 409
      # instead of destroying the new leader's lease.
      def release
        begin
          lease = read_lease
          if lease&.spec&.holder_identity == @identity
            lease.spec.holder_identity = nil
            @client.replace_namespaced_lease(@lease_name, @lease_namespace, lease)
            KrubyController.logger.info("LeaderElector: released lease #{@lease_name}/#{@lease_namespace}")
          end
        rescue Kubernetes::ApiError => e
          KrubyController.logger.warn("LeaderElector: release failed: #{e.message}")
        end
        @leader = false
      end

      def to_time(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
