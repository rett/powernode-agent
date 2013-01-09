require 'logger'

module Powernode
  module ModelExtensions
    def initialize(item)
      raise "expected Hash param" unless item.kind_of? Hash
      item.each do |key, value|
        if Powernode.config('encrypted_attributes').include?(key)
          instance_variable_set(sanitize_key(key), value)
          define_singleton_method(key.to_s) { decrypt(instance_variable_get(sanitize_key(key))) }
          define_singleton_method("#{key.to_s}=") { |val| instance_variable_set(sanitize_key(key), encrypt(val)) }
        else
          instance_variable_set(sanitize_key(key), value)
          define_singleton_method(key.to_s) { instance_variable_get(sanitize_key(key)) }
          define_singleton_method("#{key.to_s}=") { |val| instance_variable_set(sanitize_key(key), val) }
        end
        define_singleton_method('raw_' + key.to_s) { instance_variable_get(sanitize_key(key)) }
      end
      self.build_objects if self.respond_to?(:build_objects)
    end

    protected

    def sanitize_key(key)
      "@#{key.to_s.gsub(/\W/, '')}".to_sym
    end

    def decrypt(data)
      if Powernode.config('encryption_cipher') && Powernode.config('encryption_key')
        cipher = OpenSSL::Cipher.new(Powernode.config('encryption_cipher'))
        cipher.decrypt
        cipher.key = Powernode.config('encryption_key')
        decrypted_data = URI.unescape(data)
        decrypted_data = Base64.decode64(decrypted_data)
        cipher.iv = decrypted_data.slice!(0, 16)
        decrypted_data = cipher.update(decrypted_data) + cipher.final
      else
        decrypted_data = data
      end
      decrypted_data
    end

    def encrypt(data)
      if data && Powernode.config('encryption_cipher') && Powernode.config('encryption_key')
        cipher = OpenSSL::Cipher.new(Powernode.config('encryption_cipher'))
        cipher.encrypt
        cipher.key = Powernode.config('encryption_key')
        iv = cipher.random_iv
        encrypted_data = cipher.update(data) + cipher.final
        encrypted_data = iv + encrypted_data
        encrypted_data = Base64.encode64(encrypted_data)
        encrypted_data = URI.escape(encrypted_data)
      else
        encrypted_data = data
      end
      encrypted_data
    end
  end

  def self.config(key)
    @config ||= YAML.load_file(File.join(File.dirname(__FILE__), '..', 'config.yml'))
    @config[key]
  end

  def self.logger_init(file_name, cycle, log_level)
    @logger = Logger.new(File.join(Powernode.config('log_path'), file_name), cycle)
    @logger.level = Logger.const_get(log_level.upcase)
    @logger
  end

  def self.logger
    @logger ||= begin
      log = Logger.new(STDOUT)
      log.level = Logger::INFO
      log.formatter = Pretty.new
      log
    end
  end

  def logger
    Powernode.logger
  end
end
