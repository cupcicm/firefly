# encoding: UTF-8
module Firefly
  class Config < Hash

    def self.DefaultConfigFile
      File.join(Firefly.root, 'config/firefly.yml')
    end

    DEFAULTS = {
      hostname:    "localhost:3000",
      api_key:     "test",
      recent_urls: 25,
      authentication: {
        strategy: 'api_key',
        api_key: 'test'
      }
    }

    def initialize configuration_file
      self.update DEFAULTS
      self.merge! Firefly::Config.read_from_file(configuration_file)
    end

    def self.read_from_file(configuration_file)
      data = YAML::load(File.read(configuration_file))['firefly']
      data.symbolize_keys
    end
  end
end
