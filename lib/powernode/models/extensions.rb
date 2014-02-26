module PowerNode
  module ModelExtensions
    def initialize(params = {})
      raise PowerNode::HashRequiredError unless params.is_a?(Hash)
      params.each do |key, value|
        value = String.new if value.nil?
        if PowerNode.config('encrypted_attributes').include?(key) && value.match(/\A#{Regexp.escape(PowerNode.config(:encryption_prefix))}*/)
          instance_variable_set(sanitize_key(key), value.sub(/\A#{Regexp.escape(PowerNode.config(:encryption_prefix))}*/, ''))
          define_singleton_method(key.to_s) { decrypt(instance_variable_get(sanitize_key(key))) }
          define_singleton_method("#{key.to_s}=") { |val| instance_variable_set(sanitize_key(key), encrypt(val)) }
        elsif PowerNode.config('encrypted_attributes').include?(key)
          instance_variable_set(sanitize_key(key), encrypt(value))
          define_singleton_method(key.to_s) { decrypt(instance_variable_get(sanitize_key(key))) }
          define_singleton_method("#{key.to_s}=") { |val| instance_variable_set(sanitize_key(key), encrypt(val)) }
          define_singleton_method("#{key.to_s}_dirty") { true }
          define_singleton_method("dirty?") { true }
        else
          instance_variable_set(sanitize_key(key), value)
          define_singleton_method(key.to_s) { instance_variable_get(sanitize_key(key)) }
          define_singleton_method("#{key.to_s}=") { |val| instance_variable_set(sanitize_key(key), val) }
        end
        define_singleton_method('raw_' + key.to_s) { instance_variable_get(sanitize_key(key)) }
      end
      define_singleton_method('dirty?') { false } unless self.respond_to?(:dirty?)
      self.build_associations if self.respond_to?(:build_associations)
    end

    def to_hash
      Hash[instance_variables.map { |name| [name.to_s.delete("@"), instance_variable_get(name)] } ]
    end

    def to_json(*a)
      to_hash.to_json(a)
    end

    private

    def sanitize_key(key)
      "@#{key.to_s.gsub(/\W/, '')}".to_sym
    end

    def decrypt(data, encryption_cipher = PowerNode.config('encryption_cipher'), encryption_key = PowerNode.config('encryption_key'))
      if data.size > 0 && encryption_cipher && encryption_key
        cipher = OpenSSL::Cipher.new(encryption_cipher)
        cipher.decrypt
        cipher.key = encryption_key
        decrypted_data = URI.unescape(data.sub(/\A#{Regexp.escape(PowerNode.config(:encryption_prefix))}*/, ''))
        decrypted_data = Base64.decode64(decrypted_data)
        cipher.iv = decrypted_data.slice!(0, 16)
        decrypted_data = cipher.update(decrypted_data) + cipher.final
      else
        decrypted_data = data
      end
      decrypted_data
    end

    def encrypt(data, encryption_cipher = PowerNode.config('encryption_cipher'), encryption_key = PowerNode.config('encryption_key'))
      if data.size > 0 && encryption_cipher && encryption_key && !data.match(/\A#{Regexp.escape(PowerNode.config(:encryption_prefix))}*/)
        cipher = OpenSSL::Cipher.new(encryption_cipher)
        cipher.encrypt
        cipher.key = encryption_key
        iv = cipher.random_iv
        encrypted_data = cipher.update(data) + cipher.final
        encrypted_data = iv + encrypted_data
        encrypted_data = Base64.encode64(encrypted_data)
        encrypted_data = URI.escape(PowerNode.config(:encryption_prefix) + encrypted_data)
      else
        encrypted_data = data
      end
      encrypted_data
    end
  end
end
