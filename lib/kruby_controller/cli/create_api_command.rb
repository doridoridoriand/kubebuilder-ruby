# frozen_string_literal: true

module KrubyController
  module CLI
    class CreateApiCommand
      def initialize(args)
        @args = args
      end

      def run
        group = flag("group") || flag("g")
        version = flag("version") || flag("v")
        kind = flag("kind") || flag("k")
        namespaced = !@args.include?("--cluster-scoped")

        unless group && version && kind
          puts "Usage: kruby-controller create api --group <G> --version <V> --kind <K>"
          exit 1
        end

        puts "Creating API: #{group}/#{version} Kind=#{kind} (namespaced: #{namespaced})"
        # TODO: scaffold CRD class, reconciler, CRD YAML, RBAC
        puts "Done."
      end

      private

      def flag(name)
        idx = @args.index("--#{name}")
        return nil unless idx
        @args[idx + 1]
      end
    end
  end
end
