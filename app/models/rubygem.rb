class Rubygem < ActiveRecord::Base
  include Pacecar
  sluggable_finder :name

  belongs_to :user
  has_many :owners, :through => :ownerships, :source => :user
  has_many :ownerships
  has_many :versions, :dependent => :destroy
  has_one :linkset, :dependent => :destroy

  validates_presence_of :name
  validates_uniqueness_of :name

  cattr_accessor :source_index
  attr_accessor :spec, :path, :processing

  before_validation :build
  after_save :store

  def self.pull_spec(path)
    begin
      format = Gem::Format.from_file_by_path(path)
      format.spec
    rescue Exception => e
      logger.info "Problem loading gem at #{path}: #{e}"
      nil
    end
  end

  def unowned?
    ownerships.find_by_approved(true).blank?
  end

  def owned_by?(user)
    ownerships.find_by_user_id(user.id).try(:approved) if user
  end

  def to_s
    if current_version
      "#{name} (#{current_version})"
    else
      name
    end
  end

  def current_version
    versions.last
  end

  def current_dependencies
    current_version.dependencies
  end

  def with_downloads
    "#{name} (#{downloads})"
  end

  def build
    return unless self.spec

    self.name = self.spec.name if self.name.blank?

    version = self.versions.build(
      :authors     => self.spec.authors.join(", "),
      :description => self.spec.description || self.spec.summary,
      :created_at  => self.spec.date,
      :number      => self.spec.original_name.gsub("#{self.spec.name}-", ''))

    self.spec.dependencies.each do |dependency|
      version.dependencies.build(
        :rubygem_name => dependency.name,
        :name         => dependency.requirements_list.to_s)
    end

    self.build_linkset(:home => self.spec.homepage)
  end

  def store
    return unless self.spec

    cache = Gemcutter.server_path('gems', "#{self.spec.original_name}.gem")
    FileUtils.cp self.path, cache
    File.chmod 0644, cache

    source_path = Gemcutter.server_path("source_index")

    if File.exists?(source_path)
      Rubygem.source_index ||= Marshal.load(File.open(source_path))
    else
      Rubygem.source_index ||= Gem::SourceIndex.new
    end

    Rubygem.source_index.add_spec self.spec, self.spec.original_name

    unless self.processing
      File.open(source_path, "wb") do |f|
        f.write Marshal.dump(Rubygem.source_index)
      end
    end

    Gemcutter.indexer.abbreviate self.spec
    Gemcutter.indexer.sanitize self.spec

    quick_path = Gemcutter.server_path("quick", "Marshal.#{Gem.marshal_version}", "#{self.spec.original_name}.gemspec.rz")

    zipped = Gem.deflate(Marshal.dump(self.spec))
    File.open(quick_path, "wb") do |f|
      f.write zipped
    end

    Gemcutter.indexer.update_index
  end
end
