class ProviderConnection
  include Her::Model
  include_root_in_json true
  parse_root_in_json true

  belongs_to :account
  belongs_to :provider
  has_many :node_instances
  has_many :operations
  has_many :provider_regions
  has_many :provider_volumes

  def compute(provider_region)
    begin
      @compute = Fog::Compute.new(provider_options(provider_region))
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    @compute
  end

  def image
    begin
      @image = Fog::Image.new(provider_options(provider_region))
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    @image
  end

  private

  def provider_options(provider_region)
    unless @provider_options
      @provider_options = { provider: variety }
      case variety
      when 'aws'
        @provider_options[:aws_access_key_id] = access_key
        @provider_options[:aws_secret_access_key] = secret_key
        @provider_options[:endpoint] = provider_region.endpoint_url
        @provider_options[:region] = provider_region.region if provider_region.region.present?
      when 'openstack'
        @provider_options[:openstack_auth_url] = provider_region.endpoint_url + '/tokens'
        @provider_options[:openstack_username] = access_key
        @provider_options[:openstack_api_key] = secret_key
        @provider_options[:openstack_tenant] = tenant if tenant.present?
      end
    end
    @provider_options
  end
end
