class Volume
  include Her::Model

  STATUSES = %w[attached available pending provisioning]

  belongs_to :account
  belongs_to :node_instance
  belongs_to :active_instance, class_name: 'NodeInstance'
  belongs_to :provider
  has_many   :volume_members
  has_many   :volume_snapshots

  parse_root_in_json true

  Volume::STATUSES.each do |s|
    define_method(s + '?') do
      self.status == s
    end
    define_method(s + '!') do
      self.status = s
      self.save
    end
  end

  def volume_member_count
    raid? ? 2 : 1
  end

  def attach!
    if available?
      Powernode.logger.info "Attaching volume #{id} to instance #{node_instance_id}"
      self.active_instance_id = node_instance_id
      volume_members.each { |volume_member| volume_member.attach! }
      self.attached!
    end
  end

  def detach!
    if attached?
      Powernode.logger.info "Detaching volume #{id} from instance #{active_instance_id}"
      volume_members.each { |volume_member| volume_member.detach! }
      self.active_instance_id = nil
      self.available!
    end
  end

  def check!
    Powernode.logger.info "Checking volume #{id}."
    provision! if pending? || volume_members.count < volume_member_count
    volume_members.each { |volume_member| volume_member.check! } if attached? || available?
    if node_instance.present? && available?
      attach!
    elsif !node_instance.present? && attached?
      detach!
    end
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
                          status: cloud_volume.status,
                          volume_id: id)
    end
  end

  def provision!
    Powernode.logger.info "Provisioning volume #{id}."
    self.provisioning!
    (volume_member_count - volume_members.count).times { create_volume_member! }
    self.available!
  end

  def recover!
    Powernode.logger.info "Recovering volume #{id}."
    self.available!
  end
end
