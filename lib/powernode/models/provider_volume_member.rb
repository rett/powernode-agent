class ProviderVolumeMember
  include Her::Model

  STATUSES = %w[available creating provisioning]

  belongs_to :provider_volume

  parse_root_in_json true

  ProviderVolumeMember::STATUSES.each do |s|
    define_method(s + '?') do
      self.status == s
    end
    define_method(s + '!') do
      self.status = s
      self.save
    end
  end

  def attached?
    case status
    when 'attached', 'in-use'
      true
    else
      false
    end
  end

  def attached!
    self.status = 'attached'
    self.save
  end

  def check!
    Powernode.logger.info "Checking volume member #{id}"
    begin
      cloud_volume = provider_volume.provider.compute.volumes.get(entity)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    self.device = cloud_volume.attachments.first['device']
    self.status = cloud_volume.status
    self.save
  end

  def attach!
    if available? && !attached?
      Powernode.logger.info "Attaching volume member #{id} to instance #{provider_volume.node_instance_id}"
      begin
        provider_volume.provider.compute.attach_volume(entity, provider_volume.node_instance.entity, device)
        self.attached!
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def detach!
    if attached?
      Powernode.logger.info "Detaching volume member #{id} from instance #{provider_volume.active_instance_id}"
      begin
        provider_volume.provider.compute.detach_volume(provider_volume.active_instance.entity, entity)
        self.available!
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end
end
