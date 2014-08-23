class VolumeMember
  include Her::Model

  STATUSES = %w[available creating provisioning]

  belongs_to :volume

  parse_root_in_json true

  VolumeMember::STATUSES.each do |s|
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
      cloud_volume = volume.provider.compute.volumes.get(entity)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    self.device = cloud_volume.attachments.first['device']
    self.status = cloud_volume.status
    self.save
  end

  def attach!
    if available? && !attached?
      Powernode.logger.info "Attaching volume member #{id} to instance #{volume.node_instance_id}"
      begin
        volume.provider.compute.attach_volume(entity, volume.node_instance.entity, device)
        self.attached!
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end

  def detach!
    if attached?
      Powernode.logger.info "Detaching volume member #{id} from instance #{volume.active_instance_id}"
      begin
        volume.provider.compute.detach_volume(volume.active_instance.entity, entity)
        self.available!
      rescue => e
        Powernode.logger.error "Exception: #{e.message}."
      end
    end
  end
end
