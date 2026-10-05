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

      # Value of the first present value flag (nil when absent). Raises
      # UsageError when a located value flag is unterminated (present but with
      # no following value), so `init --repo --force` is reported as malformed
      # instead of silently scaffolding into the current directory.
      def flag(args, *names)
        names.each do |name|
          idx = args.index(name)
          next unless idx

          value = args[idx + 1]
          raise UsageError, "flag #{name} requires a value" if value.nil? || value.start_with?("-")

          return value
        end
        nil
      end

      # Raises UsageError when a required flag value is missing.
      def require!(value, flag_name:, usage:)
        return if value && !value.empty?

        raise UsageError, "missing required flag #{flag_name}\n#{usage}"
      end

      # Raises UsageError when an unknown option (any dash-prefixed token,
      # including short options like `-x`) is present.
      def check_known!(args, allowed)
        unknown = args.select { |a| a.start_with?("-") && !allowed.include?(a) }
        return if unknown.empty?

        raise UsageError, "unknown flag(s): #{unknown.join(', ')}"
      end

      # A Kubernetes DNS label: lowercase alphanumerics and '-', 1-63 chars,
      # starting and ending with an alphanumeric.
      def dns_label?(name)
        name.is_a?(String) && name.match?(/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
      end

      # A Kubernetes DNS subdomain: DNS labels separated by '.' (e.g.
      # "stable.example.com"), at most 253 characters total. A leading or
      # trailing dot produces an empty label and is rejected.
      def dns_subdomain?(value)
        return false unless value.is_a?(String) && !value.empty?
        return false if value.length > 253

        # split(".", -1) keeps trailing empty fields so "example.com." is
        # rejected instead of silently dropping the empty final label.
        value.split(".", -1).all? { |label| dns_label?(label) }
      end

      # Strips a trailing `.git` and normalizes +name+ into a DNS label
      # (lowercased, runs of invalid characters collapsed to '-', 1-63 chars).
      # Returns nil when nothing valid remains.
      def normalize_dns_label(name)
        label = name.to_s.sub(/\.git\z/, "").downcase
        label = label.gsub(/[^a-z0-9-]+/, "-").gsub(/-+/, "-").sub(/\A-+/, "").sub(/-\z/, "")
        label = label[0, 63].sub(/-\z/, "")
        dns_label?(label) ? label : nil
      end
    end
  end
end
