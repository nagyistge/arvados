require 'arvados/keep'
require 'sweep_trashed_collections'

class Collection < ArvadosModel
  extend DbCurrentTime
  include HasUuid
  include KindAndEtag
  include CommonApiTemplate

  serialize :properties, Hash

  before_validation :set_validation_timestamp
  before_validation :default_empty_manifest
  before_validation :check_encoding
  before_validation :check_manifest_validity
  before_validation :check_signatures
  before_validation :strip_signatures_and_update_replication_confirmed
  before_validation :ensure_trash_at_not_in_past
  before_validation :sync_trash_state
  before_validation :default_trash_interval
  validate :ensure_pdh_matches_manifest_text
  validate :validate_trash_and_delete_timing
  before_save :set_file_names

  # Query only untrashed collections by default.
  default_scope where("is_trashed = false")

  api_accessible :user, extend: :common do |t|
    t.add :name
    t.add :description
    t.add :properties
    t.add :portable_data_hash
    t.add :signed_manifest_text, as: :manifest_text
    t.add :manifest_text, as: :unsigned_manifest_text
    t.add :replication_desired
    t.add :replication_confirmed
    t.add :replication_confirmed_at
    t.add :delete_at
    t.add :trash_at
    t.add :is_trashed
  end

  after_initialize do
    @signatures_checked = false
    @computed_pdh_for_manifest_text = false
  end

  def self.attributes_required_columns
    super.merge(
                # If we don't list manifest_text explicitly, the
                # params[:select] code gets confused by the way we
                # expose signed_manifest_text as manifest_text in the
                # API response, and never let clients select the
                # manifest_text column.
                #
                # We need trash_at and is_trashed to determine the
                # correct timestamp in signed_manifest_text.
                'manifest_text' => ['manifest_text', 'trash_at', 'is_trashed'],
                'unsigned_manifest_text' => ['manifest_text'],
                )
  end

  def self.ignored_select_attributes
    super + ["updated_at", "file_names"]
  end

  FILE_TOKEN = /^[[:digit:]]+:[[:digit:]]+:/
  def check_signatures
    return false if self.manifest_text.nil?

    return true if current_user.andand.is_admin

    # Provided the manifest_text hasn't changed materially since an
    # earlier validation, it's safe to pass this validation on
    # subsequent passes without checking any signatures. This is
    # important because the signatures have probably been stripped off
    # by the time we get to a second validation pass!
    if @signatures_checked && @signatures_checked == computed_pdh
      return true
    end

    if self.manifest_text_changed?
      # Check permissions on the collection manifest.
      # If any signature cannot be verified, raise PermissionDeniedError
      # which will return 403 Permission denied to the client.
      api_token = current_api_client_authorization.andand.api_token
      signing_opts = {
        api_token: api_token,
        now: @validation_timestamp.to_i,
      }
      self.manifest_text.each_line do |entry|
        entry.split.each do |tok|
          if tok == '.' or tok.starts_with? './'
            # Stream name token.
          elsif tok =~ FILE_TOKEN
            # This is a filename token, not a blob locator. Note that we
            # keep checking tokens after this, even though manifest
            # format dictates that all subsequent tokens will also be
            # filenames. Safety first!
          elsif Blob.verify_signature tok, signing_opts
            # OK.
          elsif Keep::Locator.parse(tok).andand.signature
            # Signature provided, but verify_signature did not like it.
            logger.warn "Invalid signature on locator #{tok}"
            raise ArvadosModel::PermissionDeniedError
          elsif Rails.configuration.permit_create_collection_with_unsigned_manifest
            # No signature provided, but we are running in insecure mode.
            logger.debug "Missing signature on locator #{tok} ignored"
          elsif Blob.new(tok).empty?
            # No signature provided -- but no data to protect, either.
          else
            logger.warn "Missing signature on locator #{tok}"
            raise ArvadosModel::PermissionDeniedError
          end
        end
      end
    end
    @signatures_checked = computed_pdh
  end

  def strip_signatures_and_update_replication_confirmed
    if self.manifest_text_changed?
      in_old_manifest = {}
      if not self.replication_confirmed.nil?
        self.class.each_manifest_locator(manifest_text_was) do |match|
          in_old_manifest[match[1]] = true
        end
      end

      stripped_manifest = self.class.munge_manifest_locators(manifest_text) do |match|
        if not self.replication_confirmed.nil? and not in_old_manifest[match[1]]
          # If the new manifest_text contains locators whose hashes
          # weren't in the old manifest_text, storage replication is no
          # longer confirmed.
          self.replication_confirmed_at = nil
          self.replication_confirmed = nil
        end

        # Return the locator with all permission signatures removed,
        # but otherwise intact.
        match[0].gsub(/\+A[^+]*/, '')
      end

      if @computed_pdh_for_manifest_text == manifest_text
        # If the cached PDH was valid before stripping, it is still
        # valid after stripping.
        @computed_pdh_for_manifest_text = stripped_manifest.dup
      end

      self[:manifest_text] = stripped_manifest
    end
    true
  end

  def ensure_pdh_matches_manifest_text
    if not manifest_text_changed? and not portable_data_hash_changed?
      true
    elsif portable_data_hash.nil? or not portable_data_hash_changed?
      self.portable_data_hash = computed_pdh
    elsif portable_data_hash !~ Keep::Locator::LOCATOR_REGEXP
      errors.add(:portable_data_hash, "is not a valid locator")
      false
    elsif portable_data_hash[0..31] != computed_pdh[0..31]
      errors.add(:portable_data_hash,
                 "does not match computed hash #{computed_pdh}")
      false
    else
      # Ignore the client-provided size part: always store
      # computed_pdh in the database.
      self.portable_data_hash = computed_pdh
    end
  end

  def set_file_names
    if self.manifest_text_changed?
      self.file_names = manifest_files
    end
    true
  end

  def manifest_files
    names = ''
    if self.manifest_text
      self.manifest_text.scan(/ \d+:\d+:(\S+)/) do |name|
        names << name.first.gsub('\040',' ') + "\n"
        break if names.length > 2**12
      end
    end

    if self.manifest_text and names.length < 2**12
      self.manifest_text.scan(/^\.\/(\S+)/m) do |stream_name|
        names << stream_name.first.gsub('\040',' ') + "\n"
        break if names.length > 2**12
      end
    end

    names[0,2**12]
  end

  def default_empty_manifest
    self.manifest_text ||= ''
  end

  def check_encoding
    if manifest_text.encoding.name == 'UTF-8' and manifest_text.valid_encoding?
      true
    else
      begin
        # If Ruby thinks the encoding is something else, like 7-bit
        # ASCII, but its stored bytes are equal to the (valid) UTF-8
        # encoding of the same string, we declare it to be a UTF-8
        # string.
        utf8 = manifest_text
        utf8.force_encoding Encoding::UTF_8
        if utf8.valid_encoding? and utf8 == manifest_text.encode(Encoding::UTF_8)
          self.manifest_text = utf8
          return true
        end
      rescue
      end
      errors.add :manifest_text, "must use UTF-8 encoding"
      false
    end
  end

  def check_manifest_validity
    begin
      Keep::Manifest.validate! manifest_text
      true
    rescue ArgumentError => e
      errors.add :manifest_text, e.message
      false
    end
  end

  def signed_manifest_text
    if !has_attribute? :manifest_text
      return nil
    elsif is_trashed
      return manifest_text
    else
      token = current_api_client_authorization.andand.api_token
      exp = [db_current_time.to_i + Rails.configuration.blob_signature_ttl,
             trash_at].compact.map(&:to_i).min
      self.class.sign_manifest manifest_text, token, exp
    end
  end

  def self.sign_manifest manifest, token, exp=nil
    if exp.nil?
      exp = db_current_time.to_i + Rails.configuration.blob_signature_ttl
    end
    signing_opts = {
      api_token: token,
      expire: exp,
    }
    m = munge_manifest_locators(manifest) do |match|
      Blob.sign_locator(match[0], signing_opts)
    end
    return m
  end

  def self.munge_manifest_locators manifest
    # Given a manifest text and a block, yield the regexp MatchData
    # for each locator. Return a new manifest in which each locator
    # has been replaced by the block's return value.
    return nil if !manifest
    return '' if manifest == ''

    new_lines = []
    manifest.each_line do |line|
      line.rstrip!
      new_words = []
      line.split(' ').each do |word|
        if new_words.empty?
          new_words << word
        elsif match = Keep::Locator::LOCATOR_REGEXP.match(word)
          new_words << yield(match)
        else
          new_words << word
        end
      end
      new_lines << new_words.join(' ')
    end
    new_lines.join("\n") + "\n"
  end

  def self.each_manifest_locator manifest
    # Given a manifest text and a block, yield the regexp match object
    # for each locator.
    manifest.each_line do |line|
      # line will have a trailing newline, but the last token is never
      # a locator, so it's harmless here.
      line.split(' ').each do |word|
        if match = Keep::Locator::LOCATOR_REGEXP.match(word)
          yield(match)
        end
      end
    end
  end

  def self.normalize_uuid uuid
    hash_part = nil
    size_part = nil
    uuid.split('+').each do |token|
      if token.match(/^[0-9a-f]{32,}$/)
        raise "uuid #{uuid} has multiple hash parts" if hash_part
        hash_part = token
      elsif token.match(/^\d+$/)
        raise "uuid #{uuid} has multiple size parts" if size_part
        size_part = token
      end
    end
    raise "uuid #{uuid} has no hash part" if !hash_part
    [hash_part, size_part].compact.join '+'
  end

  # Return array of Collection objects
  def self.find_all_for_docker_image(search_term, search_tag=nil, readers=nil)
    readers ||= [Thread.current[:user]]
    base_search = Link.
      readable_by(*readers).
      readable_by(*readers, table_name: "collections").
      joins("JOIN collections ON links.head_uuid = collections.uuid").
      order("links.created_at DESC")

    # If the search term is a Collection locator that contains one file
    # that looks like a Docker image, return it.
    if loc = Keep::Locator.parse(search_term)
      loc.strip_hints!
      coll_match = readable_by(*readers).where(portable_data_hash: loc.to_s).limit(1).first
      if coll_match
        # Check if the Collection contains exactly one file whose name
        # looks like a saved Docker image.
        manifest = Keep::Manifest.new(coll_match.manifest_text)
        if manifest.exact_file_count?(1) and
            (manifest.files[0][1] =~ /^(sha256:)?[0-9A-Fa-f]{64}\.tar$/)
          return [coll_match]
        end
      end
    end

    if search_tag.nil? and (n = search_term.index(":"))
      search_tag = search_term[n+1..-1]
      search_term = search_term[0..n-1]
    end

    # Find Collections with matching Docker image repository+tag pairs.
    matches = base_search.
      where(link_class: "docker_image_repo+tag",
            name: "#{search_term}:#{search_tag || 'latest'}")

    # If that didn't work, find Collections with matching Docker image hashes.
    if matches.empty?
      matches = base_search.
        where("link_class = ? and links.name LIKE ?",
              "docker_image_hash", "#{search_term}%")
    end

    # Generate an order key for each result.  We want to order the results
    # so that anything with an image timestamp is considered more recent than
    # anything without; then we use the link's created_at as a tiebreaker.
    uuid_timestamps = {}
    matches.all.map do |link|
      uuid_timestamps[link.head_uuid] = [(-link.properties["image_timestamp"].to_datetime.to_i rescue 0),
       -link.created_at.to_i]
    end
    Collection.where('uuid in (?)', uuid_timestamps.keys).sort_by { |c| uuid_timestamps[c.uuid] }
  end

  def self.for_latest_docker_image(search_term, search_tag=nil, readers=nil)
    find_all_for_docker_image(search_term, search_tag, readers).first
  end

  def self.searchable_columns operator
    super - ["manifest_text"]
  end

  def self.full_text_searchable_columns
    super - ["manifest_text"]
  end

  def self.where *args
    SweepTrashedCollections.sweep_if_stale
    super
  end

  protected
  def portable_manifest_text
    self.class.munge_manifest_locators(manifest_text) do |match|
      if match[2] # size
        match[1] + match[2]
      else
        match[1]
      end
    end
  end

  def compute_pdh
    portable_manifest = portable_manifest_text
    (Digest::MD5.hexdigest(portable_manifest) +
     '+' +
     portable_manifest.bytesize.to_s)
  end

  def computed_pdh
    if @computed_pdh_for_manifest_text == manifest_text
      return @computed_pdh
    end
    @computed_pdh = compute_pdh
    @computed_pdh_for_manifest_text = manifest_text.dup
    @computed_pdh
  end

  def ensure_permission_to_save
    if (not current_user.andand.is_admin and
        (replication_confirmed_at_changed? or replication_confirmed_changed?) and
        not (replication_confirmed_at.nil? and replication_confirmed.nil?))
      raise ArvadosModel::PermissionDeniedError.new("replication_confirmed and replication_confirmed_at attributes cannot be changed, except by setting both to nil")
    end
    super
  end

  # Use a single timestamp for all validations, even though each
  # validation runs at a different time.
  def set_validation_timestamp
    @validation_timestamp = db_current_time
  end

  # If trash_at is being changed to a time in the past, change it to
  # now. This allows clients to say "expires {client-current-time}"
  # without failing due to clock skew, while avoiding odd log entries
  # like "expiry date changed to {1 year ago}".
  def ensure_trash_at_not_in_past
    if trash_at_changed? && trash_at
      self.trash_at = [@validation_timestamp, trash_at].max
    end
  end

  # Caller can move into/out of trash by setting/clearing is_trashed
  # -- however, if the caller also changes trash_at, then any changes
  # to is_trashed are ignored.
  def sync_trash_state
    if is_trashed_changed? && !trash_at_changed?
      if is_trashed
        self.trash_at = @validation_timestamp
      else
        self.trash_at = nil
        self.delete_at = nil
      end
    end
    self.is_trashed = trash_at && trash_at <= @validation_timestamp || false
    true
  end

  # If trash_at is updated without touching delete_at, automatically
  # update delete_at to a sensible value.
  def default_trash_interval
    if trash_at_changed? && !delete_at_changed?
      if trash_at.nil?
        self.delete_at = nil
      else
        self.delete_at = trash_at + Rails.configuration.default_trash_lifetime.seconds
      end
    end
  end

  def validate_trash_and_delete_timing
    if trash_at.nil? != delete_at.nil?
      errors.add :delete_at, "must be set if trash_at is set, and must be nil otherwise"
    end

    earliest_delete = ([@validation_timestamp, trash_at_was].compact.min +
                       Rails.configuration.blob_signature_ttl.seconds)
    if delete_at && delete_at < earliest_delete
      errors.add :delete_at, "#{delete_at} is too soon: earliest allowed is #{earliest_delete}"
    end

    if delete_at && delete_at < trash_at
      errors.add :delete_at, "must not be earlier than trash_at"
    end

    true
  end
end
