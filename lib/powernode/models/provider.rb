class Provider
  include Her::Model
  include Powernode::Encryption

  belongs_to :provider_endpoint
  has_many   :node_instances
  has_many   :volumes

  delegate :availability_zone,  to: :provider_endpoint
  delegate :endpoint_type,      to: :provider_endpoint
  delegate :machine_image,      to: :provider_endpoint
  delegate :kernel_image,       to: :provider_endpoint
  delegate :ramdisk_image,      to: :provider_endpoint
  delegate :region,             to: :provider_endpoint

  def compute
    unless @compute
      begin
        @compute = Fog::Compute.new(provider_options)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    @compute
  end

  def image
    unless @image
      begin
        @image = Fog::Image.new(provider_options)
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
    @image
  end

  private

  def provider_options
    unless @provider_options
      @provider_options = { provider: endpoint_type }
      case endpoint_type
      when 'aws'
        @provider_options[:endpoint] = provider_endpoint.endpoint_url
        @provider_options[:aws_access_key_id] = access_key
        @provider_options[:aws_secret_access_key] = secret_key
      when 'openstack'
        @provider_options[:openstack_auth_url] = provider_endpoint.endpoint_url + '/tokens'
        @provider_options[:openstack_username] = access_key
        @provider_options[:openstack_api_key] = secret_key
        @provider_options[:openstack_tenant] = tenant
      end
    end
    @provider_options
  end
end
