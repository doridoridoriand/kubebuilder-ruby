# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe KrubyController::CLI::InitCommand do
  def run(args)
    described_class.new(args).run
  end

  it "prints usage with --help and scaffolds nothing" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--help"]) }.to output(/Usage: kruby-controller init/).to_stdout
        expect(Dir.children(dir)).to be_empty
      end
    end
  end

  it "scaffolds the project structure into <repo-basename>/" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect(run(["--repo", "my.example.com/my-controller"])).to eq(0)

        base = File.join(dir, "my-controller")
        %w[
          Gemfile Rakefile .kruby-controller.yml .gitignore LICENSE
          bin/manager cmd/manager.rb
          config/crd/bases/.gitkeep config/rbac/role.yaml config/default.yaml
          pkg/crds/.gitkeep pkg/reconcilers/.gitkeep pkg/controller_suite_test.rb
          docs/README.md
        ].each do |path|
          expect(File).to exist(File.join(base, path)), "missing #{path}"
        end
        expect(File.executable?(File.join(base, "bin/manager"))).to be true
      end
    end
  end

  it "records domain, repo and license in .kruby-controller.yml" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        run(["--repo", "my.example.com/my-controller", "--domain", "corp.io", "--license", "mit"])

        yml = YAML.safe_load(File.read(File.join(dir, "my-controller/.kruby-controller.yml")))
        expect(yml).to eq(
          "name" => "my-controller", "domain" => "corp.io",
          "repo" => "my.example.com/my-controller", "license" => "mit"
        )
        expect(File.read(File.join(dir, "my-controller/LICENSE"))).to include("MIT License")
      end
    end
  end

  it "scaffolds into the current directory when --repo is omitted" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect(run([])).to eq(0)
        expect(File).to exist(File.join(dir, "cmd/manager.rb"))
        expect(File).to exist(File.join(dir, "pkg/crds/.gitkeep"))
      end
    end
  end

  it "generates a manager entrypoint wired to KrubyController::Manager" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        run(["--repo", "my.example.com/my-controller"])
        content = File.read(File.join(dir, "my-controller/cmd/manager.rb"))
        expect(content).to include('require "kruby-controller"')
        expect(content).to include("KrubyController::Manager.new")
        expect(content).to include("kube_config: ENV[\"KUBECONFIG\"]")
        expect(content).to include("manager.start")
      end
    end
  end

  it "skips LICENSE when --license none" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        run(["--repo", "my.example.com/my-controller", "--license", "none"])
        expect(File).not_to exist(File.join(dir, "my-controller/LICENSE"))
      end
    end
  end

  it "refuses to scaffold into a non-empty directory without --force" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("existing")
        File.write("existing/keep.txt", "x")
        expect { run(["--repo", "my.example.com/existing"]) }
          .to raise_error(KrubyController::CLI::UsageError, /not empty/)
        expect { run(["--repo", "my.example.com/existing", "--force"]) }.not_to raise_error
      end
    end
  end

  it "rejects unsupported licenses" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--repo", "my.example.com/x", "--license", "gpl3"]) }
          .to raise_error(KrubyController::CLI::UsageError, /unsupported license/)
      end
    end
  end

  it "rejects unknown flags" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--repo", "my.example.com/x", "--bogus"]) }
          .to raise_error(KrubyController::CLI::UsageError, /unknown flag/)
      end
    end
  end

  it "rejects unknown short flags" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--repo", "my.example.com/x", "-x"]) }
          .to raise_error(KrubyController::CLI::UsageError, /unknown flag/)
      end
    end
  end

  it "rejects an unterminated value flag instead of applying a default" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--repo", "--force"]) }
          .to raise_error(KrubyController::CLI::UsageError, /--repo requires a value/)
        expect(Dir.children(dir)).to be_empty
      end
    end
  end

  it "strips a trailing .git from the repo when deriving the project name" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect(run(["--repo", "https://github.com/acme/widget.git"])).to eq(0)
        yml = YAML.safe_load(File.read(File.join(dir, "widget/.kruby-controller.yml")))
        expect(yml["name"]).to eq("widget")
        # The Namespace in the default manifest must be a valid DNS label.
        default_yaml = File.read(File.join(dir, "widget/config/default.yaml"))
        expect(default_yaml).to match(/kind: Namespace\nmetadata:\n\s+name: widget\n/)
      end
    end
  end

  it "rejects a domain that is not a DNS subdomain" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { run(["--repo", "my.example.com/x", "--domain", "corp_internal"]) }
          .to raise_error(KrubyController::CLI::UsageError, /invalid --domain/)
      end
    end
  end

  it "binds the manager ClusterRole to the ServiceAccount in the default manifest" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        run(["--repo", "my.example.com/my-controller"])
        default_yaml = File.read(File.join(dir, "my-controller/config/default.yaml"))
        expect(default_yaml).to include("kind: ClusterRoleBinding")
        expect(default_yaml).to include("name: my-controller-manager-role")
        expect(default_yaml).to include("name: my-controller-manager\n")
        expect(default_yaml).to include("namespace: my-controller")
      end
    end
  end

  it "keeps the Deployment label value within the 63-character limit" do
    long_name = "a" * 63
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        run(["--repo", "example.com/#{long_name}"])
        default_yaml = File.read(File.join(dir, long_name, "config/default.yaml"))
        # The label value uses the unsuffixed project name (<=63 chars); the
        # Deployment/SA object names may still carry the -manager suffix.
        expect(default_yaml).to include("app: #{long_name}\n")
        expect(default_yaml).not_to include("app: #{long_name}-manager")
        expect(default_yaml).to include("name: #{long_name}-manager\n")
      end
    end
  end
end
