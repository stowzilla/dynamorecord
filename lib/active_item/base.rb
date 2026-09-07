# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/array/extract_options'
require 'active_model'
require 'securerandom'

module ActiveItem
  # Base class for all ActiveItem models. Provides persistence, callbacks,
  # validations, dirty tracking, and an ActiveRecord-like interface for
  # DynamoDB tables.
  class Base
    include ActiveModel::Validations
    include ActiveModel::Dirty
    extend ActiveModel::Callbacks
    include Associations
    include Embeddable
    include Logging

    define_model_callbacks :save, :create, :update, :destroy, :initialize, :validation

    def self.const_missing(name)
      ActiveItem.const_defined?(name) ? ActiveItem.const_get(name) : super
    end

    prepend ComposedOf

    extend DatabaseHelpers
    extend QueryHelpers
    extend Validations

    attr_reader :id
    attr_accessor :created_at, :updated_at, :dbrecord

    def id=(value)
      @id = (value.to_s.strip.empty? ? nil : value)
    end

    before_create :generate_primary_key
    before_create :assign_created_timestamp
    before_destroy :check_dependent_associations

    def initialize(attributes = {})
      @_preloaded_counts = {}
      @_preloaded_associations = {}
      @new_record = true

      return unless attributes.is_a?(Hash)

      attributes.each do |key, value|
        setter = "#{key}="
        send(setter, value) if respond_to?(setter)
      end

      clear_changes_information
    end

    def _preloaded_counts
      @_preloaded_counts ||= {}
    end

    def _preloaded_associations
      @_preloaded_associations ||= {}
    end

    def self.attribute_names
      @attribute_names ||= instance_methods.grep(/\A[a-z_][a-z0-9_]*=\z/).map { |m| m.to_s.chomp('=') }.sort
    end

    def populate_attributes_from_item(item)
      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'id'

        value = nil
        found = false
        self.class.dynamo_key_variants(attr_name).each do |key|
          next unless item.key?(key)

          value = item[key]
          found = true
          break
        end

        instance_variable_set("@#{attr_name}", value) if found
      end

      @created_at = item['createdAt'] || item['created_at']
      @updated_at = item['updatedAt'] || item['updated_at']

      populate_custom_attributes_from_item(item) if respond_to?(:populate_custom_attributes_from_item, true)
      populate_composed_attributes_from_item(item) if self.class.respond_to?(:compositions) && self.class.compositions.any?
    end

    class << self
      def attr_accessor(*attrs)
        attrs.each do |attr|
          attr_name = attr.to_s

          define_attribute_methods attr_name

          define_method(attr_name) do
            instance_variable_get("@#{attr_name}")
          end

          define_method("#{attr_name}=") do |value|
            old_value = instance_variable_get("@#{attr_name}")
            send("#{attr_name}_will_change!") if (old_value != value) && !changed_attributes.key?(attr_name)
            instance_variable_set("@#{attr_name}", value)
          end
        end
      end

      def primary_key
        @primary_key ||= 'id'
      end

      def primary_key=(value)
        remove_method primary_key.to_sym
        remove_method :"#{primary_key}="

        @primary_key = value.to_s

        alias_method primary_key.to_sym, :id
        alias_method :"#{primary_key}=", :id=
      end

      def table_name
        @table_name || default_table_name
      end

      def table_name=(value)
        @table_name = value.to_s
      end

      def dynamodb
        @dynamodb ||= Aws::DynamoDB::Client.new(http_wire_trace: false)
      end

      attr_writer :dynamodb

      def dynamo_attribute_map(mappings = nil)
        if mappings
          @dynamo_attribute_map = mappings.transform_keys(&:to_s)
        else
          @dynamo_attribute_map || {}
        end
      end

      def to_dynamo_key(attr_name)
        attr_str = attr_name.to_s
        return dynamo_attribute_map[attr_str] if dynamo_attribute_map.key?(attr_str)

        attr_str.camelize(:lower)
      end

      def from_dynamo_key(dynamo_key)
        key_str = dynamo_key.to_s
        reverse_map = dynamo_attribute_map.invert
        return reverse_map[key_str] if reverse_map.key?(key_str)

        key_str.underscore
      end

      def dynamo_key_variants(attr_name)
        attr_str = attr_name.to_s
        primary_key = to_dynamo_key(attr_str)
        camel_case = attr_str.camelize(:lower)
        [primary_key, camel_case, attr_str].uniq
      end

      def instantiate(item)
        normalized_item = normalize_dynamodb_values(item)

        record = allocate
        record.instance_variable_set(:@id, normalized_item[primary_key])
        record.send(:populate_attributes_from_item, normalized_item)
        record.send(:populate_embedded_associations, normalized_item)
        record.instance_variable_set(:@new_record, false)
        record.instance_variable_set(:@mutations_from_database, nil)
        record.instance_variable_set(:@dbrecord, normalized_item)
        record.send(:clear_changes_information)
        record
      end

      def normalize_dynamodb_values(obj)
        case obj
        when BigDecimal
          obj.frac.zero? ? obj.to_i : obj.to_f
        when Hash
          obj.transform_values { |v| normalize_dynamodb_values(v) }
        when Array
          obj.map { |v| normalize_dynamodb_values(v) }
        else
          obj
        end
      end

      def find_or_create_by(attributes, &block)
        record = find_by(**attributes)
        return record if record

        record = new(**attributes)
        block.call(record) if block_given?
        record.save
        record
      end

      # Callback DSL — :on option routes before_save/after_save to create/update
      def before_save(*args, &)
        options = args.extract_options!
        if options[:on]
          case options[:on].to_sym
          when :create then set_callback(:create, :before, *args, &)
          when :update then set_callback(:update, :before, *args, &)
          else raise ArgumentError, "Invalid on: option '#{options[:on]}'. Must be :create or :update"
          end
        else
          set_callback(:save, :before, *args, &)
        end
      end

      def after_save(*args, &)
        options = args.extract_options!
        if options[:on]
          case options[:on].to_sym
          when :create then set_callback(:create, :after, *args, &)
          when :update then set_callback(:update, :after, *args, &)
          else raise ArgumentError, "Invalid on: option '#{options[:on]}'. Must be :create or :update"
          end
        else
          set_callback(:save, :after, *args, &)
        end
      end

      def scope(name, body)
        raise ArgumentError, 'scope body must be callable (Proc/Lambda)' unless body.respond_to?(:call)

        _scopes[name.to_sym] = body
        define_singleton_method(name) { all.instance_exec(&body) }
      end

      def _scopes
        @_scopes ||= {}
      end

      private

      def default_table_name
        raise 'Cannot generate table name for anonymous class' unless name

        ActiveItem.configuration.table_name_for(name)
      end

      def inherited(subclass)
        super
        subclass.class_eval do
          alias_method primary_key.to_sym, :id
          alias_method :"#{primary_key}=", :id=
        end
      end
    end

    def new_record?
      @new_record != false
    end

    def persisted?
      !new_record?
    end

    def reload
      raise 'Cannot reload a new record' if new_record?

      fresh_record = self.class.find(id)
      raise "Record not found: #{self.class.name} with id #{id}" unless fresh_record

      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'dbrecord'

        value = fresh_record.instance_variable_get("@#{attr_name}")
        instance_variable_set("@#{attr_name}", value)
      end

      @created_at = fresh_record.created_at
      @updated_at = fresh_record.updated_at
      @dbrecord = fresh_record.dbrecord
      clear_changes_information
      self
    end

    def has_changes_to_save?
      changed? || embedded_associations_changed?
    end

    def to_h
      attributes.with_indifferent_access
    end

    def attributes
      attrs = {}
      pk_name = self.class.primary_key
      pk_value = begin
        send(pk_name)
      rescue StandardError
        instance_variable_get("@#{pk_name}")
      end
      attrs['id'] = pk_value
      attrs[pk_name] = pk_value

      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'dbrecord'

        value = instance_variable_get("@#{attr_name}")
        attrs[attr_name] = value unless value.nil?
      end

      attrs['created_at'] = @created_at
      attrs['updated_at'] = @updated_at
      attrs
    end

    def inspect
      begin
        send(self.class.primary_key)
      rescue StandardError
        id
      end
      attr_strs = self.class.attribute_names.filter_map do |attr|
        next if attr == 'dbrecord'

        value = instance_variable_get("@#{attr}")
        next if value.nil?

        "#{attr}: #{value.inspect}"
      end
      "#<#{self.class.name} #{attr_strs.join(', ')}>"
    end

    def update(attributes)
      assign_attributes(attributes)
      save
    end

    def update!(attributes)
      assign_attributes(attributes)
      save!
    end

    def save(validate: true)
      return save_via_parent(validate: validate) if self.class.embedded? && !@_saving_via_parent

      return false if validate && !run_validations

      # If inside a transaction block, enroll this save in the transaction
      return enroll_in_transaction if Transaction.active?

      result = run_callbacks :save do
        if new_record?
          run_callbacks(:create) { perform_create }
        else
          run_callbacks(:update) { perform_update }
        end
      end

      return false if result == false

      changes_applied
      @new_record = false
      true
    rescue StandardError => e
      dynamo_logger.error("Failed to save #{self.class.name}: #{e.message}")
      raise e
    end

    def save!
      raise RecordInvalid.new(self), "Validation failed: #{errors.full_messages.join(', ')}" unless save

      true
    end

    def self.create(attributes = {})
      raise_embedded_error!(:create) if respond_to?(:embedded?) && embedded?

      obj = new(attributes)
      obj.save
      obj
    end

    def self.create!(attributes = {})
      raise_embedded_error!(:create!) if respond_to?(:embedded?) && embedded?

      obj = new(attributes)
      obj.save!
      obj
    end

    # Execute a block within a transaction context.
    #
    # Supports two usage patterns:
    #
    # 1. Explicit API (block receives transaction):
    #      Model.transaction do |txn|
    #        txn.put(record1)
    #        txn.update(record2)
    #      end
    #
    # 2. Implicit API (transactional saves):
    #      Model.transaction do
    #        record1.save!
    #        record2.save!
    #        record3.destroy!
    #      end
    #
    # In the implicit API, save/destroy calls are automatically enrolled.
    # The transaction is committed when the block completes successfully.
    # If an exception is raised, no changes are committed (all-or-nothing).
    #
    # @yield [Transaction] the transaction object (optional)
    # @raise [TransactionError] if the transaction fails
    def self.transaction
      txn = Transaction.new
      Transaction.current = txn
      begin
        # Support both explicit (yield txn) and implicit (no block param) APIs
        yield txn if block_given?
        txn.execute!
      ensure
        Transaction.current = nil
      end
    end

    def self.transaction_find(items)
      return [] if items.empty?
      raise TransactionError, "DynamoDB transactions are limited to 100 items (got #{items.length})" if items.length > 100

      transact_items = items.map do |item|
        { get: { table_name: item[:model].table_name, key: { item[:model].primary_key.to_s => item[:key] } } }
      end

      client = items.first[:model].dynamodb
      response = client.transact_get_items(transact_items: transact_items)

      response.responses.each_with_index.map do |resp, idx|
        items[idx][:model].instantiate(resp.item) if resp.item
      end
    rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
      raise TransactionError, "Transaction read cancelled: #{e.message}"
    end

    def destroy
      return destroy_via_parent if self.class.embedded? && !@_destroying_via_parent

      # If inside a transaction block, enroll this destroy in the transaction
      return enroll_destroy_in_transaction if Transaction.active?

      result = run_callbacks(:destroy) { perform_destroy }
      return false if result == false

      true
    rescue ActiveItem::EmbeddedModelError
      raise
    rescue DeleteRestrictionError
      false
    rescue StandardError => e
      dynamo_logger.error("Failed to destroy #{self.class.name}: #{e.message}")
      errors.add(:base, e.message)
      false
    end

    def destroy!
      raise RecordNotDestroyed.new(nil, self) unless destroy

      true
    end

    def delete
      perform_destroy
      true
    rescue StandardError => e
      dynamo_logger.error("Failed to delete #{self.class.name}: #{e.message}")
      false
    end

    def assign_attributes(attributes)
      attributes.each do |key, value|
        setter = "#{key}="
        send(setter, value) if respond_to?(setter)
      end
    end

    def attribute_changed?(attr_name)
      super(attr_name.to_s)
    end

    def attribute_was(attr_name)
      changed_attributes[attr_name.to_s]
    end

    def valid?(context = nil)
      return super if defined?(@running_validations) && @running_validations

      @running_validations = true
      begin
        run_callbacks(:validation) { super(context) }
      ensure
        @running_validations = false
      end
    end

    private

    # Enroll this record's save operation in the current transaction.
    # Called when save is invoked inside a transaction block.
    def enroll_in_transaction
      txn = Transaction.current

      result = run_callbacks :save do
        if new_record?
          run_callbacks(:create) { txn.put(self) }
        else
          run_callbacks(:update) { txn.update(self) }
        end
      end

      return false if result == false

      # Mark changes as applied (will be committed when transaction executes)
      # Note: @new_record stays true until transaction.execute! completes
      true
    end

    # Enroll this record's destroy operation in the current transaction.
    # Called when destroy is invoked inside a transaction block.
    def enroll_destroy_in_transaction
      txn = Transaction.current

      result = run_callbacks(:destroy) { txn.delete(self) }
      return false if result == false

      true
    end

    def generate_primary_key
      @id = nil if @id.to_s.strip.empty?
      @id ||= SecureRandom.uuid

      pk = self.class.primary_key
      instance_variable_set("@#{pk}", @id) if pk != 'id'
    end

    def assign_created_timestamp
      @created_at ||= Time.now.utc.iso8601 # rubocop:disable Naming/MemoizedInstanceVariableName
    end

    def dynamodb
      self.class.dynamodb
    end

    def table_name
      self.class.table_name
    end

    def run_validations
      context = new_record? ? :create : :update
      return false unless valid?(context)

      # Cascade validations into embedded collections
      validate_embedded_associations
    end

    # Hydrate embedded associations from a DynamoDB item hash.
    def populate_embedded_associations(item)
      self.class._embedded_associations.each do |assoc_name, config|
        dynamo_key = self.class.to_dynamo_key(assoc_name.to_s)
        raw_array = item[dynamo_key]
        next unless raw_array.is_a?(Array)

        target_class = safe_constantize_model(config[:class_name])
        records = raw_array.map do |hash|
          record = Embeddable.from_embedded_hash(target_class, hash)
          record.instance_variable_set(:@_embedded_parent, self)
          record
        end

        collection = EmbeddedCollection.new(
          owner: self,
          association_name: assoc_name,
          target_class: target_class,
          records: records
        )
        instance_variable_set(:"@_embedded_#{assoc_name}", collection)

        # Snapshot for dirty tracking
        instance_variable_set(:"@_embedded_#{assoc_name}_snapshot", serialize_embedded_snapshot(collection))
      end
    end

    # Validate all embedded associations. Returns true if all valid, false otherwise.
    def validate_embedded_associations
      all_valid = true

      self.class._embedded_associations.each_key do |assoc_name|
        collection = send(assoc_name)
        collection.each_with_index do |record, idx|
          next if record.valid?

          all_valid = false
          record.errors.each do |error|
            errors.add(:"#{assoc_name}[#{idx}].#{error.attribute}", error.message)
          end
        end
      end

      all_valid
    end

    # Run callbacks on embedded records during parent save.
    def run_embedded_callbacks(callback_type)
      self.class._embedded_associations.each_key do |assoc_name|
        collection = send(assoc_name)
        collection.each do |record|
          record.instance_variable_set(:@_saving_via_parent, true)
          record.run_callbacks(callback_type) { nil } if record.respond_to?(:run_callbacks, true)
          record.instance_variable_set(:@_saving_via_parent, false)
        end
      end
    end

    # Delegate save from an embedded record to its parent.
    # This allows `thing.save` and `thing.update(attrs)` to work
    # by persisting through the parent record.
    def save_via_parent(validate: true)
      parent = instance_variable_get(:@_embedded_parent)
      unless parent
        raise ActiveItem::EmbeddedModelError,
              "Cannot save #{self.class.name} — no parent record. " \
              "Build embedded records through the parent's collection (e.g., parent.things.build)."
      end

      return false if validate && respond_to?(:valid?) && !valid?

      parent.save(validate: validate)
    end

    # Delegate destroy from an embedded record to its parent.
    # Removes itself from the parent's collection and saves the parent.
    def destroy_via_parent
      parent = instance_variable_get(:@_embedded_parent)
      unless parent
        raise ActiveItem::EmbeddedModelError,
              "Cannot destroy #{self.class.name} — no parent record."
      end

      # Find which collection this record belongs to and remove it
      self.class.superclass # ensure class is loaded
      parent.class._embedded_associations.each do |assoc_name, config|
        target_class = parent.send(:safe_constantize_model, config[:class_name])
        next unless is_a?(target_class)

        collection = parent.send(assoc_name)
        collection.records.delete(self)
        break
      end

      parent.save
    end

    # Snapshot the serialized state of an embedded collection for dirty comparison.
    def serialize_embedded_snapshot(collection)
      collection.map(&:to_embedded_hash)
    end

    # Check if any embedded collection has changed since load.
    def embedded_associations_changed?
      self.class._embedded_associations.any? do |assoc_name, _config|
        current = send(assoc_name)
        snapshot = instance_variable_get(:"@_embedded_#{assoc_name}_snapshot") || []
        serialize_embedded_snapshot(current) != snapshot
      end
    end

    # Update snapshots after a successful write so subsequent saves
    # don't re-persist unchanged embedded data.
    def snapshot_embedded_associations
      self.class._embedded_associations.each_key do |assoc_name|
        collection = send(assoc_name)
        instance_variable_set(:"@_embedded_#{assoc_name}_snapshot", serialize_embedded_snapshot(collection))
      end
    end

    # Detect the DynamoDB 400KB item size limit error and re-raise
    # as a friendlier ActiveItem::ItemTooLargeError.
    def raise_if_item_too_large(error)
      return unless error.message.include?('Item size') || error.message.include?('item size') ||
                    error.message.include?('400') || error.message.include?('exceeds')

      raise ActiveItem::ItemTooLargeError.new(
        model_name: self.class.name,
        table: table_name,
        original_error: error
      )
    end

    def perform_create
      run_embedded_callbacks(:create)
      run_embedded_callbacks(:save)

      item = build_dynamodb_item
      item['createdAt'] = @created_at
      item['updatedAt'] = Time.now.utc.iso8601
      item['_recent_pk'] ||= 'ALL'

      dynamodb.put_item(
        table_name: table_name,
        item: item,
        condition_expression: 'attribute_not_exists(#pk)',
        expression_attribute_names: { '#pk' => self.class.primary_key.to_s }
      )

      snapshot_embedded_associations
      dynamo_logger.info("#{self.class.name} created (#{self.class.primary_key}: #{id})")
    rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
      errors.add(:id, 'already exists')
      false
    rescue Aws::DynamoDB::Errors::ValidationException => e
      raise_if_item_too_large(e)
      raise
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise ActiveItem::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                              operation: 'PutItem', original_error: e)
    end

    def build_dynamodb_item
      item = { self.class.primary_key.to_s => id }

      dynamodb_attributes.each do |attr|
        value = instance_variable_get("@#{attr}")
        next if value.nil?

        dynamo_key = self.class.to_dynamo_key(attr)
        item[dynamo_key] = value
      end

      # Serialize embedded collections
      self.class._embedded_associations.each_key do |assoc_name|
        collection = send(assoc_name)
        next if collection.nil? || collection.empty?

        dynamo_key = self.class.to_dynamo_key(assoc_name.to_s)
        item[dynamo_key] = collection.map(&:to_embedded_hash)
      end

      validate_gsi_key_types!(item)

      item
    end

    def dynamodb_attributes
      attrs = self.class.attribute_names - [self.class.primary_key.sub('_id', ''), 'id', 'dbrecord']

      if self.class.respond_to?(:compositions) && self.class.compositions.any?
        composed_attrs = self.class.compositions.values.flat_map { |c| c[:mapping].keys.map(&:to_s) }
        attrs -= composed_attrs
      end

      # Embedded associations are serialized separately in build_dynamodb_item
      if self.class._embedded_associations.any?
        embedded_names = self.class._embedded_associations.keys.map(&:to_s)
        attrs -= embedded_names
      end

      attrs
    end

    def perform_update
      embedded_changed = embedded_associations_changed?
      return if changes.empty? && !embedded_changed

      # Validate GSI key types for changed attributes before building the update
      validate_gsi_key_types_for_changes!

      run_embedded_callbacks(:update) if embedded_changed
      run_embedded_callbacks(:save) if embedded_changed

      update_parts = []
      remove_parts = []
      attr_values = {}
      attr_names = {}
      idx = 0

      changes.each do |field, (_old_val, new_val)|
        next if field == 'updated_at'
        # Skip embedded association fields — handled separately below
        next if self.class._embedded_associations.key?(field.to_sym)

        dynamo_key = self.class.to_dynamo_key(field)
        if new_val.nil?
          remove_parts << "#field#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
        else
          update_parts << "#field#{idx} = :val#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
          attr_values[":val#{idx}"] = new_val
        end
        idx += 1
      end

      # Serialize changed embedded associations into the update expression
      self.class._embedded_associations.each_key do |assoc_name|
        collection = send(assoc_name)
        snapshot = instance_variable_get(:"@_embedded_#{assoc_name}_snapshot") || []
        current_serialized = serialize_embedded_snapshot(collection)
        next if current_serialized == snapshot

        dynamo_key = self.class.to_dynamo_key(assoc_name.to_s)
        if collection.empty?
          remove_parts << "#field#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
        else
          update_parts << "#field#{idx} = :val#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
          attr_values[":val#{idx}"] = current_serialized
        end
        idx += 1
      end

      update_parts << '#updatedAt = :updatedAt'
      attr_names['#updatedAt'] = 'updatedAt'
      attr_values[':updatedAt'] = Time.now.utc.iso8601

      update_expression = "SET #{update_parts.join(', ')}"
      update_expression += " REMOVE #{remove_parts.join(', ')}" if remove_parts.any?

      params = {
        table_name: table_name,
        key: { self.class.primary_key.to_s => id },
        update_expression: update_expression,
        expression_attribute_values: attr_values
      }
      params[:expression_attribute_names] = attr_names if attr_names.any?

      dynamodb.update_item(params)
      snapshot_embedded_associations
    rescue Aws::DynamoDB::Errors::ValidationException => e
      raise_if_item_too_large(e)
      raise
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise ActiveItem::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                              operation: 'UpdateItem', original_error: e)
    end

    def perform_destroy
      key = self.class.primary_key.to_s
      dynamodb.delete_item(table_name: table_name, key: { key => send(key) })
      dynamo_logger.info("#{self.class.name} deleted (#{key}: #{send(key)})")
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise ActiveItem::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                              operation: 'DeleteItem', original_error: e)
    end

    # Validates that all GSI key attributes have valid types for DynamoDB.
    # GSI keys can only be String, Number (Integer/Float/BigDecimal), or Binary (StringIO).
    #
    # @param item [Hash] The DynamoDB item being built
    # @raise [InvalidGsiKeyTypeError] if any GSI key has an invalid type
    def validate_gsi_key_types!(item)
      return unless self.class.respond_to?(:indexes)

      indexes = self.class.indexes
      return if indexes.nil? || indexes.empty?

      indexes.each do |index_name, config|
        # Check partition key
        partition_key = config[:partition_key]&.to_s
        if partition_key && item.key?(partition_key)
          value = item[partition_key]
          validate_gsi_key_value!(partition_key, value, index_name) unless value.nil?
        end

        # Check sort key if present
        sort_key = config[:sort_key]&.to_s
        if sort_key && item.key?(sort_key)
          value = item[sort_key]
          validate_gsi_key_value!(sort_key, value, index_name) unless value.nil?
        end
      end
    end

    # Validates GSI key types for changed attributes during updates.
    # Only validates the attributes that are being changed, not the entire item.
    #
    # @raise [InvalidGsiKeyTypeError] if any changed GSI key has an invalid type
    def validate_gsi_key_types_for_changes!
      return unless self.class.respond_to?(:indexes)

      indexes = self.class.indexes
      return if indexes.nil? || indexes.empty?

      # Build a hash of changed dynamo keys and their new values
      changed_dynamo_keys = {}
      changes.each do |field, (_old_val, new_val)|
        next if new_val.nil? # nil values are being removed, no type validation needed

        dynamo_key = self.class.to_dynamo_key(field)
        changed_dynamo_keys[dynamo_key] = new_val
      end

      return if changed_dynamo_keys.empty?

      indexes.each do |index_name, config|
        # Check partition key if it's being changed
        partition_key = config[:partition_key]&.to_s
        validate_gsi_key_value!(partition_key, changed_dynamo_keys[partition_key], index_name) if partition_key && changed_dynamo_keys.key?(partition_key)

        # Check sort key if it's being changed
        sort_key = config[:sort_key]&.to_s
        validate_gsi_key_value!(sort_key, changed_dynamo_keys[sort_key], index_name) if sort_key && changed_dynamo_keys.key?(sort_key)
      end
    end

    # Validates that a single GSI key value has a valid type.
    # DynamoDB GSI keys support: String, Number (Integer/Float/BigDecimal), Binary (StringIO).
    # Empty strings are not allowed for GSI keys.
    #
    # @param attribute [String] The attribute name
    # @param value [Object] The attribute value
    # @param index_name [String] The GSI name (for error messages)
    # @raise [InvalidGsiKeyTypeError] if the value has an invalid type
    def validate_gsi_key_value!(attribute, value, index_name)
      return if valid_gsi_key_type?(value)

      raise InvalidGsiKeyTypeError.new(
        model_name: self.class.name,
        attribute: attribute,
        index_name: index_name,
        value: value
      )
    end

    # Checks if a value is a valid type for a DynamoDB GSI key.
    # Valid types: String (non-empty), Numeric (Integer, Float, BigDecimal), Binary (StringIO).
    # Empty strings are explicitly rejected as DynamoDB does not allow them for key attributes.
    #
    # @param value [Object] The value to check
    # @return [Boolean] true if the value is a valid GSI key type
    def valid_gsi_key_type?(value)
      case value
      when String
        !value.empty? # Empty strings are not allowed for GSI keys
      when Integer, Float, BigDecimal, StringIO
        # Numeric (Integer, Float, BigDecimal) and Binary (StringIO) are valid GSI key types
        true
      else
        false
      end
    end
  end
end
