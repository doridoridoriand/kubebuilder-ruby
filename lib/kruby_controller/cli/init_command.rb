# frozen_string_literal: true

require "fileutils"
require "yaml"
require "kruby_controller/cli/flag_parser"

module KrubyController
  module CLI
    # `kruby-controller init` — scaffolds a new project (design doc §2.10.2).
    class InitCommand
      DEFAULT_DOMAIN = "example.com"
      DEFAULT_LICENSE = "apache2"
      SUPPORTED_LICENSES = %w[apache2 mit none].freeze
      ALLOWED_FLAGS = %w[--domain --repo --license --force -h --help].freeze

      USAGE = <<~USAGE.freeze
        Usage: kruby-controller init [options]

        Scaffolds a new KrubyController project.

        Options:
          --domain <domain>    API domain suffix (default: #{DEFAULT_DOMAIN})
          --repo <repo>        Repository URL/path; the project directory is
                               created in the current directory under its last
                               segment (default: scaffold in the current
                               directory)
          --license <license>  #{SUPPORTED_LICENSES.join(' | ')} (default: #{DEFAULT_LICENSE})
          --force              Allow scaffolding into a non-empty directory
          -h, --help           Show this help
      USAGE

      def initialize(args)
        @args = args
      end

      def run
        if FlagParser.help?(@args)
          puts USAGE
          return 0
        end

        domain = FlagParser.flag(@args, "--domain") || DEFAULT_DOMAIN
        repo = FlagParser.flag(@args, "--repo")
        license = FlagParser.flag(@args, "--license") || DEFAULT_LICENSE
        force = FlagParser.flag?(@args, "--force")
        FlagParser.check_known!(@args, ALLOWED_FLAGS)

        unless FlagParser.dns_subdomain?(domain)
          raise UsageError,
                "invalid --domain #{domain.inspect}; must be a DNS subdomain (lowercase labels separated by '.')"
        end

        unless SUPPORTED_LICENSES.include?(license)
          raise UsageError, "unsupported license #{license.inspect}; expected one of #{SUPPORTED_LICENSES.join(', ')}"
        end

        @domain = domain
        @repo = repo
        @license = license
        @name, @target_dir = resolve_target(repo)
        validate_target!(force)

        scaffold
        0
      end

      private

      def resolve_target(repo)
        if repo.nil? || repo == "."
          name = FlagParser.normalize_dns_label(File.basename(Dir.pwd))
          raise UsageError, "cannot derive a valid project name from #{Dir.pwd}" if name.nil?

          return [name, Dir.pwd]
        end

        name = FlagParser.normalize_dns_label(File.basename(File.expand_path(repo)))
        raise UsageError, "cannot derive a valid project name from --repo #{repo.inspect}" if name.nil?

        [name, File.join(Dir.pwd, name)]
      end

      def validate_target!(force)
        return unless File.exist?(@target_dir)

        raise UsageError, "target path #{@target_dir} is a file" if File.file?(@target_dir)

        entries = Dir.children(@target_dir)
        return if entries.empty? || force

        raise UsageError, "directory #{@target_dir} is not empty (use --force to scaffold anyway)"
      end

      def scaffold
        puts "Initializing KrubyController project #{@name.inspect}..."
        puts "  domain:  #{@domain}"
        puts "  license: #{@license}"

        files = {
          "Gemfile" => gemfile,
          "Rakefile" => rakefile,
          ".kruby-controller.yml" => project_yml,
          "bin/manager" => bin_manager,
          "cmd/manager.rb" => cmd_manager,
          "config/crd/bases/.gitkeep" => "",
          "config/rbac/role.yaml" => rbac_role,
          "config/default.yaml" => default_deployment,
          "pkg/crds/.gitkeep" => "",
          "pkg/reconcilers/.gitkeep" => "",
          "pkg/controller_suite_test.rb" => controller_suite_test,
          "docs/README.md" => docs_readme,
          ".gitignore" => gitignore
        }
        files["LICENSE"] = license_file if @license != "none"

        files.each do |relative_path, content|
          write_file(relative_path, content)
        end
        File.chmod(0o755, File.join(@target_dir, "bin/manager"))

        puts "Created:"
        files.each_key { |p| puts "  #{display_path(p)}" }
        puts "Done. Next steps:"
        puts next_steps
        0
      end

      def write_file(relative_path, content)
        path = File.join(@target_dir, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end

      def display_path(relative_path)
        @target_dir == Dir.pwd ? relative_path : File.join(@target_dir, relative_path)
      end

      def next_steps
        lines = []
        lines << "  cd #{File.basename(@target_dir)}" unless @target_dir == Dir.pwd
        lines << "  bundle install"
        lines << "  kruby-controller create api --group stable --version v1 --kind CronTask"
        lines.join("\n")
      end

      def gemfile
        <<~RUBY
          # frozen_string_literal: true

          source "https://rubygems.org"

          gem "kruby-controller"

          group :development, :test do
            gem "rake", "~> 13.0"
            gem "rspec", "~> 3.13"
            gem "rubocop", "~> 1.70"
          end
        RUBY
      end

      def rakefile
        <<~RUBY
          # frozen_string_literal: true

          require "rspec/core/rake_task"

          RSpec::Core::RakeTask.new(:spec) do |t|
            t.pattern = "pkg/**/*_test.rb"
          end

          task default: :spec
        RUBY
      end

      def project_yml
        YAML.dump(
          "name" => @name,
          "domain" => @domain,
          "repo" => @repo || ".",
          "license" => @license
        )
      end

      def bin_manager
        <<~RUBY
          #!/usr/bin/env ruby
          # frozen_string_literal: true

          require_relative "../cmd/manager"
        RUBY
      end

      def cmd_manager
        <<~RUBY
          # frozen_string_literal: true

          require "kruby-controller"

          manager = KrubyController::Manager.new(
            kube_config: ENV["KUBECONFIG"],
            leader_elect: true
          )

          # Register controllers here. `kruby-controller create api` appends
          # a manager.add(<Reconciler>, for: <Kind>) line before manager.start.

          manager.start
        RUBY
      end

      def rbac_role
        <<~YAML
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRole
          metadata:
            name: #{@name}-manager-role
          rules:
            # Leader election
            - apiGroups: ["coordination.k8s.io"]
              resources: ["leases"]
              verbs: ["get", "create", "update", "patch"]
        YAML
      end

      def default_deployment
        <<~YAML
          # Default manifests for the #{@name} manager.
          apiVersion: v1
          kind: Namespace
          metadata:
            name: #{@name}
          ---
          apiVersion: v1
          kind: ServiceAccount
          metadata:
            name: #{@name}-manager
            namespace: #{@name}
          ---
          # Bind the base manager ClusterRole (leader election) to the manager
          # ServiceAccount so the deployment can acquire coordination leases.
          apiVersion: rbac.authorization.k8s.io/v1
          kind: ClusterRoleBinding
          metadata:
            name: #{@name}-manager-rolebinding
          roleRef:
            apiGroup: rbac.authorization.k8s.io
            kind: ClusterRole
            name: #{@name}-manager-role
          subjects:
            - kind: ServiceAccount
              name: #{@name}-manager
              namespace: #{@name}
          ---
          apiVersion: apps/v1
          kind: Deployment
          metadata:
            name: #{@name}-manager
            namespace: #{@name}
          spec:
            replicas: 1
            selector:
              matchLabels:
                app: #{@name}-manager
            template:
              metadata:
                labels:
                  app: #{@name}-manager
              spec:
                serviceAccountName: #{@name}-manager
                containers:
                  - name: manager
                    image: #{@name}:latest # TODO: build and push your image
                    command: ["ruby", "bin/manager"]
        YAML
      end

      def controller_suite_test
        <<~RUBY
          # frozen_string_literal: true

          require "kruby-controller"

          RSpec.describe "generated project" do
            it "loads the kruby-controller framework" do
              expect(KrubyController).to be_const_defined(:Manager)
            end

            it "can build a manager without a cluster" do
              manager = KrubyController::Manager.new(kube_config: nil, leader_elect: false)
              expect(manager).to be_a(KrubyController::Manager)
            end
          end
        RUBY
      end

      def docs_readme
        <<~MARKDOWN
          # #{@name}

          A Kubernetes controller project generated by `kruby-controller init`.

          ## Quickstart

          ```sh
          bundle install
          kruby-controller create api --group stable --version v1 --kind CronTask
          bundle exec rake
          ruby bin/manager
          ```

          ## Layout

          | Path | Purpose |
          |---|---|
          | `cmd/manager.rb` | Manager entry point; `create api` appends `manager.add(...)` |
          | `pkg/crds/` | CRD class definitions (KrubyController::CRD DSL) |
          | `pkg/reconcilers/` | Reconciler implementations |
          | `config/crd/bases/` | Generated CRD YAML manifests |
          | `config/rbac/` | RBAC manifests |
          | `config/default.yaml` | Namespace / ServiceAccount / Deployment |
        MARKDOWN
      end

      def gitignore
        <<~TEXT
          .bundle/
          vendor/bundle/
          *.gem
        TEXT
      end

      def license_file
        case @license
        when "apache2"
          <<~LICENSE
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

                    Copyright #{Time.now.year} #{@repo || @name}

            Licensed under the Apache License, Version 2.0 (the "License");
            you may not use this file except in compliance with the License.
            You may obtain a copy of the License at

                http://www.apache.org/licenses/LICENSE-2.0

            Unless required by applicable law or agreed to in writing, software
            distributed under the License is distributed on an "AS IS" BASIS,
            WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
            implied. See the License for the specific language governing
            permissions and limitations under the License.
          LICENSE
        when "mit"
          <<~LICENSE
            MIT License

            Copyright (c) #{Time.now.year} #{@repo || @name}

            Permission is hereby granted, free of charge, to any person obtaining a copy
            of this software and associated documentation files (the "Software"), to deal
            in the Software without restriction, including without limitation the rights
            to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
            copies of the Software, and to permit persons to whom the Software is
            furnished to do so, subject to the following conditions:

            The above copyright notice and this permission notice shall be included in all
            copies or substantial portions of the Software.

            THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
            IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
            FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
            AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
            LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
            OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
            SOFTWARE.
          LICENSE
        end
      end
    end
  end
end
