class Volume
  include Her::Model

  belongs_to :account
  belongs_to :node_instance
  belongs_to :provider
  has_many   :volume_members
  has_many   :volume_snapshots

  parse_root_in_json true

  def volume_member_count
    raid? ? 2 : 1
  end

  def attach!
    detach! if attached?
    Powernode.logger.info "Attaching volume #{id} to instance #{node_instance_id}"
    self.active_instance_id = node_instance_id
    volume_members.each { |volume_member| volume_member.attach! }
    self.attached = true
    self.save
  end

  def detach!
    if attached?
      Powernode.logger.info "Detaching volume #{id} from instance #{active_instance_id}"
      volume_members.each { |volume_member| volume_member.detach! }
      self.attached = false
      self.save
    end
  end

  def check!
    Powernode.logger.info "Checking volume #{id}."
    volume_members.each { |volume_member| volume_member.check! }
  end

  def create_volume_member!
    Powernode.logger.info "Creating volume member for volume #{id}."
    volume_member_options = { availability_zone: provider.availability_zone,
                              description: '',
                              name: '',
                              size: size }
    begin
      cloud_volume = provider.compute.volumes.create(volume_member_options)
    rescue => e
      Powernode.logger.error "Exception: #{e.message}."
    end
    if cloud_volume
      VolumeMember.create(entity: cloud_volume.id,
                          name: cloud_volume.id,
                          status: cloud_volume.state,
                          volume_id: id)
    end
  end

  def provision!
    Powernode.logger.info "Provisioning volume #{id}."
    self.status = 'provisioning'
    self.save
    (volume_member_count - volume_members.count).times { create_volume_member! } if volume_members.count < volume_member_count
    self.status = 'available'
    self.save
  end

  def recover!
    Powernode.logger.info "Recovering volume #{id}."
    self.status = 'available'
    self.save
  end
end
