module Powernode
  module ModelExtensions
    def initialize(item)
      raise "expected Hash param" unless item.kind_of? Hash
      item.each do |key, value|
        instance_variable_set(clean_key(key), value)
        define_singleton_method(key.to_s) { instance_variable_get( clean_key(key) ) }
        define_singleton_method("#{key.to_s}=") { |val| instance_variable_set( clean_key(key), val ) }
      end
      self.build_objects if self.respond_to?(:build_objects)
    end

    protected

    def clean_key key
      "@#{key.to_s.gsub(/^\@/, "").gsub(/=$/, "")}".to_sym
    end
  end
end
