# frozen_string_literal: true

module KrubyController
  module CLI
    class InitCommand
      def initialize(args)
        @args = args
      end

      def run
        domain = flag("domain") || "example.com"
        repo = flag("repo") || "."
        license = flag("license") || "apache2"
        puts "Initializing KrubyController project..."
        puts "  domain:  #{domain}"
        puts "  repo:    #{repo}"
        puts "  license: #{license}"
        # TODO: scaffold project structure
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
