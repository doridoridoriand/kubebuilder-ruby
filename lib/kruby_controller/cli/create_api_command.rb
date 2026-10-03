# frozen_string_literal: true

require "fileutils"
require "yaml"
require "kruby_controller/cli/flag_parser"
require "kruby_controller/generator/crd_generator"

module KrubyController
  module CLI
    # `kruby-controller create api` — scaffolds a CRD class, reconciler,
    # CRD YAML, RBAC, and manager wiring (design doc §2.10.3).
    class CreateApiCommand
      PROJECT_FILE = ".kruby-controller.yml"
      ALLOWED_FLAGS = %w[
        --group --version --kind --resource
        --cluster-scoped --no-controller --make --force
        -g -v -k -h --help
      ].freeze

      USAGE = <<~USAGE
        Usage: kruby-controller create api --group <G> --kind <K> [options]

        Creates a new API type inside a kruby-controller project
        (requires .kruby-controller.yml; run `kruby-controller init` first).

        Options:
          -g, --group <group>      API group prefix; the full group is
                                   "<group>.<domain>" from the project file (required)
          -k, --kind <kind>        Kind name, e.g. CronTask (required)
          -v, --version <version>  API version (default: v1)
          --resource <resource>    Plural resource name override
          --cluster-scoped         Resource is cluster-scoped (default: namespaced)
          --no-controller          Skip the reconciler and manager wiring
          --make                   Syntax-check generated Ruby files after scaffolding
          --force                  Overwrite existing generated files
          -h, --help               Show this help
      USAGE

      KIND_PATTERN = /\A[A-Z][A-Za-z0-9]*\z/
      GROUP_PATTERN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
      VERSION_PATTERN = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

      def initialize(args, root: Dir.pwd)
        @args = args
        @root = root
      end

      def run
        if FlagParser.help?(@args)
          puts USAGE
          return 0
        end

        group = FlagParser.flag(@args, "--group", "-g")
        version = FlagParser.flag(@args, "--version", "-v") || "v1"
        kind = FlagParser.flag(@args, "--kind", "-k")
        resource = FlagParser.flag(@args, "--resource")
        cluster_scoped = FlagParser.flag?(@args, "--cluster-scoped")
        no_controller = FlagParser.flag?(@args, "--no-controller")
        make = FlagParser.flag?(@args, "--make")
        force = FlagParser.flag?(@args, "--force")
        FlagParser.check_known!(@args, ALLOWED_FLAGS)

        FlagParser.require!(group, flag_name: "--group", usage: USAGE)
        FlagParser.require!(kind, flag_name: "--kind", usage: USAGE)

        unless KIND_PATTERN.match?(kind)
          raise UsageError, "kind must start with an uppercase letter (got #{kind.inspect})"
        end
        unless GROUP_PATTERN.match?(group)
          raise UsageError, "group must be a lowercase DNS label (got #{group.inspect})"
        end
        unless VERSION_PATTERN.match?(version)
          raise UsageError, "version must be lowercase alphanumerics separated by '-' (got #{version.inspect})"
        end

        @project = load_project!
        @domain = @project["domain"] || "example.com"
        @group = "#{group}.#{@domain}"
        @version = version
        @kind = kind
        @resource = resource
        @namespaced = !cluster_scoped
        @force = force
        @snake = snake_case(kind)
        @plural = resource || default_plural
        @created = []

        scaffold_crd_class
        scaffold_rbac
        unless no_controller
          scaffold_reconciler
          update_manager
        end
        make_check if make

        puts "Created API: #{@group}/#{@version} Kind=#{@kind} (scope: #{@namespaced ? 'Namespaced' : 'Cluster'})"
        @created.each { |p| puts "  #{p}" }
        puts "Done."
        0
      end

      private

      def load_project!
        path = File.join(@root, PROJECT_FILE)
        unless File.file?(path)
          raise UsageError,
                "not a kruby-controller project (no #{PROJECT_FILE} in #{Dir.pwd}); run `kruby-controller init` first"
        end

        YAML.safe_load(File.read(path)) || {}
      end

      def default_plural
        word = @kind.downcase
        if word.end_with?("s", "x", "z", "ch", "sh")
          "#{word}es"
        elsif word.end_with?("y") && !%w[a e i o u].include?(word[-2])
          "#{word[0..-2]}ies"
        else
          "#{word}s"
        end
      end

      def snake_case(str)
        str.sub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
           .sub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      def crd_class_path
        File.join(@root, "pkg/crds", "#{@snake}.rb")
      end

      def scaffold_crd_class
        namespaced_line = "  self.namespaced = #{@namespaced}\n"
        plural_line = @resource ? "  self.plural = \"#{@resource}\"\n" : ""
        content = +<<~RUBY
          # frozen_string_literal: true

          require "kruby-controller"

          # #{@kind} is the Schema for the #{@group} #{@plural} API.
          class #{@kind}
            include KrubyController::CRD

            self.group = "#{@group}"
            self.version = "#{@version}"
            self.kind = "#{@kind}"
        RUBY
        content << plural_line if @resource
        content << namespaced_line
        content << <<~RUBY

            # Spec
            attribute :example, type: :string, description: "TODO: describe this field"

            # Status
            status_attribute :example, type: :string, description: "TODO: describe this field"
          end
        RUBY

        write_generated(crd_class_path, content)
        scaffold_crd_yaml
      end

      def scaffold_crd_yaml
        if Object.const_defined?(@kind, false)
          raise UsageError, "top-level constant #{@kind} is already defined; choose a different --kind"
        end

        code = File.read(crd_class_path)
        # Force the class declaration onto Object so eval does not nest the
        # constant inside the CLI class's lexical scope.
        code = code.sub(/^class\s+#{Regexp.escape(@kind)}\b/m) { |m| m.sub(@kind, "::#{@kind}") }
        yaml =
          begin
            eval(code, binding, crd_class_path) # rubocop:disable Security/Eval
            Generator::CrdGenerator.new(Object.const_get(@kind)).generate_yaml
          ensure
            Object.send(:remove_const, @kind) if Object.const_defined?(@kind, false)
          end

        write_generated(File.join(@root, "config/crd/bases", "#{@group}_#{@plural}.yaml"), yaml)
      end

      def scaffold_rbac
        content = <<~YAML
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRole
          metadata:
            name: #{@snake}-role
          rules:
            - apiGroups: ["#{@group}"]
              resources: ["#{@plural}"]
              verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
            - apiGroups: ["#{@group}"]
              resources: ["#{@plural}/status"]
              verbs: ["get", "update", "patch"]
        YAML
        write_generated(File.join(@root, "config/rbac", "#{@snake}_role.yaml"), content)
      end

      def reconciler_path
        File.join(@root, "pkg/reconcilers", "#{@snake}_reconciler.rb")
      end

      def scaffold_reconciler
        content = <<~RUBY
          # frozen_string_literal: true

          require "kruby-controller"

          class #{@kind}Reconciler < KrubyController::Reconciler
            def reconcile(request)
              # TODO: implement the reconcile logic for #{@kind}.
              # Read the object (cache / api client), reconcile the desired
              # state, then return one of:
              #   KrubyController::Result.ok
              #   KrubyController::Result.retry_after(30)
              #   KrubyController::Result.requeue
              KrubyController::Result.ok
            end
          end
        RUBY
        write_generated(reconciler_path, content)
      end

      def manager_path
        File.join(@root, "cmd/manager.rb")
      end

      def update_manager
        path = manager_path
        unless File.file?(path)
          warn "warning: #{path} not found; skipping manager wiring"
          return
        end

        content = File.read(path)
        changed = false

        require_line = "require_relative \"../pkg/crds/#{@snake}\""
        unless content.include?(require_line)
          content = content.sub(/(require "kruby-controller")/) { |m| "#{m}\n#{require_line}" }
          changed = true
        end

        reconciler_require = "require_relative \"../pkg/reconcilers/#{@snake}_reconciler\""
        unless content.include?(reconciler_require)
          crd_line = "require_relative \"../pkg/crds/#{@snake}\""
          content = content.sub(crd_line) { |m| "#{m}\n#{reconciler_require}" }
          changed = true
        end

        add_line = "manager.add(#{@kind}Reconciler, for: #{@kind})"
        unless content.include?(add_line)
          if content.match?(/^manager\.start\s*$/)
            content = content.sub(/^manager\.start\s*$/,
                                  "manager.add(#{@kind}Reconciler, for: #{@kind})\nmanager.start")
          else
            warn "warning: could not find `manager.start` in #{path}; add `#{add_line}` manually"
            return
          end
          changed = true
        end

        return unless changed

        File.write(path, content)
        @created << relative_to_root(path)
      end

      def write_generated(path, content)
        if File.exist?(path) && !@force
          raise UsageError, "file exists: #{relative_to_root(path)} (use --force to overwrite)"
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        @created << relative_to_root(path)
      end

      def make_check
        ruby_files = @created.select { |p| p.end_with?(".rb") }.map { |p| File.join(@root, p) }
        return if ruby_files.empty?

        ruby_files.each do |file|
          ok = system("ruby", "-c", file, out: File::NULL, err: File::NULL)
          raise UsageError, "syntax check failed for #{relative_to_root(file)}" unless ok
        end

        puts "make: syntax check passed (#{ruby_files.size} file(s))"
      end

      def relative_to_root(path)
        path.sub(%r{\A#{Regexp.escape(@root)}/}, "")
      end
    end
  end
end
