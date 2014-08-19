module Powernode
  module Encryption
    extend ActiveSupport::Concern

    included do
      after_initialize :decryption_init
      before_save :encryption_init
    end

    private

    def decryption_init
      update_server = false
      (Powernode.config(:encrypted_attributes) & attributes.keys).each do |attribute|
        define_singleton_method(attribute) { decrypt(attributes[attribute]) }
        update_server = true unless attributes[attribute] && attributes[attribute].match(/\A#{Regexp.escape(Powernode.config(:encryption_prefix))}*/)
      end
      self.save if update_server
    end

    def encryption_init
      (Powernode.config(:encrypted_attributes) & attributes.keys).each do |attribute|
        attributes[attribute] = encrypt(attributes[attribute])
      end
    end

    def decrypt(data, encryption_cipher = Powernode.config(:encryption_cipher), encryption_key = Powernode.config(:encryption_key))
      data ||= ''
      if data.size > 0 && encryption_cipher && encryption_key && data.match(/\A#{Regexp.escape(Powernode.config(:encryption_prefix))}*/)
        cipher = OpenSSL::Cipher.new(encryption_cipher)
        cipher.decrypt
        cipher.key = encryption_key
        decrypted_data = URI.unescape(data.sub(/\A#{Regexp.escape(Powernode.config(:encryption_prefix))}*/, ''))
        decrypted_data = Base64.decode64(decrypted_data)
        cipher.iv = decrypted_data.slice!(0, 16)
        decrypted_data = cipher.update(decrypted_data) + cipher.final
      else
        decrypted_data = data
      end
      decrypted_data
    end

    def encrypt(data, encryption_cipher = Powernode.config(:encryption_cipher), encryption_key = Powernode.config(:encryption_key))
      data ||= ''
      if data && data.size > 0 && encryption_cipher && encryption_key && !data.match(/\A#{Regexp.escape(Powernode.config(:encryption_prefix))}*/)
        cipher = OpenSSL::Cipher.new(encryption_cipher)
        cipher.encrypt
        cipher.key = encryption_key
        iv = cipher.random_iv
        encrypted_data = cipher.update(data) + cipher.final
        encrypted_data = iv + encrypted_data
        encrypted_data = Base64.encode64(encrypted_data)
        encrypted_data = URI.escape(Powernode.config(:encryption_prefix) + encrypted_data)
      elsif data
        encrypted_data = data
      end
      encrypted_data
    end
  end
end
