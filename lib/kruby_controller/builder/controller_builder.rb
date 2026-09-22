# frozen_string_literal: true

module KrubyController
  module Builder
    class ControllerBuilder
      def initialize(manager, for_gvk)
        @manager = manager
        @for_gvk = for_gvk
        @owns = []
        @watches = []
        @predicate = nil
        @max_concurrent = 1
      end

      def for(gvk)
        @for_gvk = gvk
        self
      end

      def owns(gvk)
        @owns << gvk
        self
      end

      def watches(gvk, predicate: nil, handler: nil)
        @watches << { gvk:, predicate:, handler: }
        self
      end

      def with_max_concurrent_reconciles(n)
        @max_concurrent = n
        self
      end

      def with_predicate(predicate)
        @predicate = predicate
        self
      end

      def complete_with(reconciler)
        @manager.add(
          reconciler,
          for_gvk: @for_gvk,
          max_concurrent: @max_concurrent,
          owns: @owns,
          watches: @watches,
          predicate: @predicate
        )
      end
    end
  end
end
