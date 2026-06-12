# frozen_string_literal: true

module KrubyController
  def self.logger
    @logger ||= Logger.new($stdout).tap { |l| l.progname = "kruby-controller" }
  end

  def self.logger=(logger)
    @logger = logger
  end
end
