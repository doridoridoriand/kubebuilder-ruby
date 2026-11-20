# frozen_string_literal: true

require_relative "lib/kruby_controller/version"

Gem::Specification.new do |spec|
  spec.name = "kruby-controller"
  spec.version = KrubyController::VERSION
  spec.summary = "Kubernetes Controller Framework for Ruby"
  spec.description = "A controller-runtime equivalent for Ruby, built on kruby (Kubernetes Ruby client). " \
                     "Provides Reconcile Loop, Shared Cache, Event Handler, Leader Election, and more."
  spec.authors = ["Takahiro Ishida"]
  spec.email = ["takahiro.ishida@cyberagent.co.jp"]

  spec.homepage = "https://github.com/doridoridoriand/kubebuilder-ruby"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Package only the runtime files. Without FNM_DOTMATCH the glob skips
  # dotfiles (e.g. a stray .DS_Store on a developer's machine is never
  # bundled), and directories are dropped so the spec lists real files only.
  spec.files = Dir.glob("{lib,exe}/**/*").reject { |f| File.directory?(f) } +
               %w[LICENSE README.md Rakefile]
  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }

  spec.add_dependency "kruby", "~> 1.36"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.70"
end
