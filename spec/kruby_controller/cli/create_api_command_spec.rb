# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe KrubyController::CLI::CreateApiCommand do
  def in_project(args = ["--repo", "example.com/proj"])
    Dir.mktmpdir do |dir|
      root = nil
      Dir.chdir(dir) do
        KrubyController::CLI::InitCommand.new(args).run
        root = File.join(dir, "proj")
        Dir.chdir(root) do
          yield root
        end
      end
    end
  end

  def create_api(*args)
    described_class.new(args).run
  end

  it "prints usage with --help and scaffolds nothing" do
    in_project do |root|
      before = Dir.children(root).sort
      expect { create_api("--help") }.to output(/Usage: kruby-controller create api/).to_stdout
      expect(Dir.children(root).sort).to eq(before)
    end
  end

  it "requires --group and --kind" do
    in_project do
      expect { create_api("--kind", "CronTask") }.to raise_error(KrubyController::CLI::UsageError, /--group/)
      expect { create_api("--group", "stable") }.to raise_error(KrubyController::CLI::UsageError, /--kind/)
    end
  end

  it "validates kind, group and version format" do
    in_project do
      expect { create_api("--group", "stable", "--kind", "cronTask") }
        .to raise_error(KrubyController::CLI::UsageError, /kind must start with an uppercase/)
      expect { create_api("--group", "Stable", "--kind", "CronTask") }
        .to raise_error(KrubyController::CLI::UsageError, /lowercase DNS label/)
      expect { create_api("--group", "stable", "--kind", "CronTask", "--version", "v1.0") }
        .to raise_error(KrubyController::CLI::UsageError, /version/)
    end
  end

  it "refuses to run outside a kruby-controller project" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        expect { create_api("--group", "stable", "--kind", "CronTask") }
          .to raise_error(KrubyController::CLI::UsageError, /not a kruby-controller project/)
      end
    end
  end

  it "creates the CRD class, reconciler, CRD YAML, RBAC and manager wiring" do
    in_project do |root|
      expect(create_api("--group", "stable", "--version", "v1", "--kind", "CronTask", "--make")).to eq(0)

      crd = File.read(File.join(root, "pkg/crds/cron_task.rb"))
      expect(crd).to include("class CronTask")
      expect(crd).to include('self.group = "stable.example.com"')
      expect(crd).to include('self.kind = "CronTask"')
      expect(crd).to include("self.namespaced = true")
      expect(crd).to include("attribute :example, type: :string")

      reconciler = File.read(File.join(root, "pkg/reconcilers/cron_task_reconciler.rb"))
      expect(reconciler).to include("class CronTaskReconciler < KrubyController::Reconciler")
      expect(reconciler).to include("KrubyController::Result.ok")

      manifest = YAML.safe_load(File.read(File.join(root, "config/crd/bases/stable.example.com_crontasks.yaml")))
      expect(manifest["metadata"]["name"]).to eq("crontasks.stable.example.com")
      expect(manifest["spec"]["group"]).to eq("stable.example.com")
      expect(manifest["spec"]["scope"]).to eq("Namespaced")
      expect(manifest["spec"]["names"]["plural"]).to eq("crontasks")

      rbac = YAML.safe_load(File.read(File.join(root, "config/rbac/cron_task_role.yaml")))
      expect(rbac["rules"].first["apiGroups"]).to eq(["stable.example.com"])
      expect(rbac["rules"].first["resources"]).to eq(["crontasks"])

      manager = File.read(File.join(root, "cmd/manager.rb"))
      expect(manager).to include('require_relative "../pkg/crds/cron_task"')
      expect(manager).to include('require_relative "../pkg/reconcilers/cron_task_reconciler"')
      expect(manager).to include("manager.add(CronTaskReconciler, for: CronTask)")
      expect(manager).to match(/manager\.add\(CronTaskReconciler, for: CronTask\)\nmanager\.start/)
    end
  end

  it "supports cluster-scoped resources and --resource overrides" do
    in_project do |root|
      create_api("--group", "stable", "--kind", "ClusterThing", "--cluster-scoped", "--resource", "clustercats")

      crd = File.read(File.join(root, "pkg/crds/cluster_thing.rb"))
      expect(crd).to include("self.namespaced = false")
      expect(crd).to include('self.plural = "clustercats"')

      manifest = YAML.safe_load(File.read(File.join(root, "config/crd/bases/stable.example.com_clustercats.yaml")))
      expect(manifest["spec"]["scope"]).to eq("Cluster")
      expect(manifest["spec"]["names"]["plural"]).to eq("clustercats")
    end
  end

  it "--no-controller skips the reconciler and manager wiring" do
    in_project do |root|
      create_api("--group", "stable", "--kind", "CronTask", "--no-controller")

      expect(File).not_to exist(File.join(root, "pkg/reconcilers/cron_task_reconciler.rb"))
      manager = File.read(File.join(root, "cmd/manager.rb"))
      expect(manager).not_to include("require_relative")
      expect(manager).not_to include("manager.add(CronTask")
    end
  end

  it "is idempotent with --force: no duplicate manager wiring" do
    in_project do |root|
      create_api("--group", "stable", "--kind", "CronTask")
      create_api("--group", "stable", "--kind", "CronTask", "--force")

      manager = File.read(File.join(root, "cmd/manager.rb"))
      expect(manager.scan(/^manager\.add/).size).to eq(1)
      expect(manager.scan('require_relative "../pkg/crds/cron_task"').size).to eq(1)
    end
  end

  it "refuses to overwrite existing files without --force" do
    in_project do |_root|
      create_api("--group", "stable", "--kind", "CronTask")
      expect { create_api("--group", "stable", "--kind", "CronTask") }
        .to raise_error(KrubyController::CLI::UsageError, /file exists.*--force/)
    end
  end

  it "rejects unknown flags" do
    in_project do
      expect { create_api("--group", "stable", "--kind", "CronTask", "--bogus") }
        .to raise_error(KrubyController::CLI::UsageError, /unknown flag/)
    end
  end
end
