class VolumeMember
  include Her::Model

  belongs_to :volume

  parse_root_in_json true

  after_initialize do
    if device.blank?
      chars = 'fghjkmnp'
      self.device = '/dev/vd' + chars[rand(chars.size)]
      self.save
    end
  end

  def attach!
    detach! if attached?
    Powernode.logger.info "Attaching volume member #{id} to instance #{volume.node_instance_id}"
    # volume.provider.compute.attach_volume(volume.node_instance.entity, entity, device)
    self.attached = true
    self.save
  end

  def detach!
    if attached?
      Powernode.logger.info "Detaching volume member #{id} from instance #{volume.active_instance_id}"
      # volume.provider.compute.detach_volume(volume.node_instance.entity)
      self.attached = false
      self.save
    end
  end

  def check!
    Powernode.logger.info "Checking volume member #{id}"
    begin
      cloud_volume = volume.provider.compute.volumes.get(entity)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    if cloud_volume
      self.status = cloud_volume.state
      self.save
    end
  end
end
