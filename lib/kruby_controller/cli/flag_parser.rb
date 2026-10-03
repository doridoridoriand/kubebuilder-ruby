# frozen_string_literal: true

module KrubyController
  module CLI
    # Raised for invalid command line usage (missing/unknown flags, bad values).
    class UsageError < StandardError; end

    # Minimal ARGV-style flag parser shared by CLI commands.
    module FlagParser
      module_function

      HELP_FLAGS = %w[-h --help].freeze

      def help?(args)
        args.any? { |a| HELP_FLAGS.include?(a) }
      end

      # True if any of the boolean flags is present.
      def flag?(args, *names)
        names.any? { |name| args.include?(name) }
      end

      # Value of the first present --flag (nil when absent or unterminated).
      def flag(args, *names)
        names.each do |name|
          idx = args.index(name)
          next unless idx

          value = args[idx + 1]
          return value if value && !value.start_with?("--", "-")
        end
        nil
      end

      # Raises UsageError when a required flag value is missing.
      def require!(value, flag_name:, usage:)
        return if value && !value.empty?

        raise UsageError, "missing required flag #{flag_name}\n#{usage}"
      end

      # Raises UsageError when an unknown --flag is present.
      def check_known!(args, allowed)
        unknown = args.select { |a| a.start_with?("--") && !allowed.include?(a) }
        return if unknown.empty?

        raise UsageError, "unknown flag(s): #{unknown.join(', ')}"
      end
    end
  end
end
