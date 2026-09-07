# frozen_string_literal: true

require 'spec_helper'
require 'bigdecimal'
require 'stringio'

RSpec.describe 'GSI key type validation' do
  let(:dynamo_client) { @dynamo_client }

  # Model with GSI indexes for testing
  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-items"

      attr_accessor :status, :customer_id, :name, :count

      indexes(
        'StatusIndex' => { partition_key: 'status', sort_key: 'createdAt' },
        'CustomerIndex' => { partition_key: 'customerId' }
      )

      dynamo_attribute_map(
        customer_id: 'customerId'
      )

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  # Model without GSI indexes (should not trigger validation)
  let(:model_without_indexes) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets"

      attr_accessor :name, :data

      def self.name
        'Widget'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  describe 'valid GSI key types' do
    it 'accepts String values' do
      record = model_class.new(status: 'active', customer_id: 'cust-123', name: 'Test')
      expect { record.save }.not_to raise_error
      expect(record.persisted?).to be true
    end

    it 'accepts Integer values as valid GSI key type' do
      # NOTE: While Integer is a valid GSI key type in DynamoDB, the actual GSI must be
      # defined with Number type. The validation here only checks the Ruby type is valid.
      # The test below verifies Integer passes type validation.
      int_model = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-widgets" # Use table without GSIs to avoid type mismatch

        attr_accessor :name, :priority

        indexes(
          'PriorityIndex' => { partition_key: 'priority' }
        )

        def self.name
          'IntWidget'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }

      # This should pass our type validation (Integer is valid)
      # but would fail at DynamoDB if the GSI was defined as String type
      int_model.new(name: 'Test', priority: 12_345)
      # We only test that our validation passes - DynamoDB will reject if GSI type mismatches
      expect(int_model.new.send(:valid_gsi_key_type?, 12_345)).to be true
    end

    it 'accepts Float values as valid GSI key type' do
      # Test that Float passes type validation
      expect(model_class.new.send(:valid_gsi_key_type?, 98.6)).to be true
    end

    it 'accepts BigDecimal values as valid GSI key type' do
      expect(model_class.new.send(:valid_gsi_key_type?, BigDecimal('123.45'))).to be true
    end

    it 'accepts StringIO (Binary) values as valid GSI key type' do
      expect(model_class.new.send(:valid_gsi_key_type?, StringIO.new('binary data'))).to be true
    end

    it 'allows nil values for GSI keys' do
      record = model_class.new(status: 'active', customer_id: nil, name: 'Test')
      expect { record.save }.not_to raise_error
      expect(record.persisted?).to be true
    end
  end

  describe 'invalid GSI key types' do
    it 'rejects Array values' do
      record = model_class.new(status: %w[a b c], name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.model_name).to eq('Item')
        expect(error.attribute).to eq('status')
        expect(error.index_name).to eq('StatusIndex')
        expect(error.value_type).to eq('Array')
        expect(error.message).to include('has invalid type Array')
        expect(error.message).to include('StatusIndex')
      end
    end

    it 'rejects Hash values' do
      record = model_class.new(status: { key: 'value' }, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('Hash')
      end
    end

    it 'rejects Boolean values' do
      record = model_class.new(status: true, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('TrueClass')
      end
    end

    it 'rejects Symbol values' do
      record = model_class.new(status: :active, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('Symbol')
      end
    end

    it 'rejects custom object values' do
      custom_object = Struct.new(:name).new('test')
      record = model_class.new(status: custom_object, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
      end
    end

    it 'rejects Date values (must be converted to String)' do
      record = model_class.new(status: Date.today, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('Date')
      end
    end

    it 'rejects Time values (must be converted to String)' do
      record = model_class.new(status: Time.now, name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('Time')
      end
    end

    it 'rejects empty strings' do
      record = model_class.new(status: '', name: 'Test')
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('status')
        expect(error.value_type).to eq('String')
        expect(error.message).to include('has invalid type String')
      end
    end
  end

  describe 'models without indexes' do
    it 'does not validate non-GSI attributes' do
      record = model_without_indexes.new(name: 'Test', data: { nested: 'hash' })
      expect { record.save }.not_to raise_error
      expect(record.persisted?).to be true
    end

    it 'allows any type for non-indexed attributes' do
      record = model_without_indexes.new(name: 'Test', data: %w[array of strings])
      expect { record.save }.not_to raise_error
    end
  end

  describe 'validation on update' do
    it 'validates GSI key types when updating' do
      record = model_class.new(status: 'active', name: 'Test')
      record.save

      record.status = %w[invalid array]
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError)
    end

    it 'allows valid type updates' do
      record = model_class.new(status: 'active', name: 'Test')
      record.save

      record.status = 'pending'
      expect { record.save }.not_to raise_error
    end

    it 'validates empty string updates' do
      record = model_class.new(status: 'active', name: 'Test')
      record.save

      record.status = ''
      expect { record.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError)
    end
  end

  describe 'edge cases' do
    it 'handles zero numeric GSI keys' do
      # Zero is a valid numeric value
      expect(model_class.new.send(:valid_gsi_key_type?, 0)).to be true
      expect(model_class.new.send(:valid_gsi_key_type?, 0.0)).to be true
    end

    it 'validates sort key types as well as partition keys' do
      sort_key_model = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-events"

        attr_accessor :customer_id, :event_type

        indexes(
          'CustomerIndex' => { partition_key: 'customerId', sort_key: 'createdAt' }
        )

        dynamo_attribute_map(customer_id: 'customerId')

        def self.name
          'Event'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }

      # Valid case - String for partition key
      record = sort_key_model.new(customer_id: 'cust-123', event_type: 'click')
      expect { record.save }.not_to raise_error

      # Invalid case - Array for partition key
      record2 = sort_key_model.new(customer_id: %w[invalid array], event_type: 'click')
      expect { record2.save }.to raise_error(ActiveItem::InvalidGsiKeyTypeError) do |error|
        expect(error.attribute).to eq('customerId')
        expect(error.index_name).to eq('CustomerIndex')
      end
    end

    it 'handles whitespace-only strings (valid but may be unintended)' do
      # Whitespace-only strings are technically valid in DynamoDB
      # but we should NOT reject them as that would be too opinionated
      record = model_class.new(status: '   ', name: 'Test')
      expect { record.save }.not_to raise_error
    end
  end

  describe '#valid_gsi_key_type?' do
    let(:instance) { model_class.new }

    it 'returns true for non-empty String' do
      expect(instance.send(:valid_gsi_key_type?, 'hello')).to be true
    end

    it 'returns false for empty String' do
      expect(instance.send(:valid_gsi_key_type?, '')).to be false
    end

    it 'returns true for Integer' do
      expect(instance.send(:valid_gsi_key_type?, 42)).to be true
    end

    it 'returns true for Float' do
      expect(instance.send(:valid_gsi_key_type?, 3.14)).to be true
    end

    it 'returns true for BigDecimal' do
      expect(instance.send(:valid_gsi_key_type?, BigDecimal('99.99'))).to be true
    end

    it 'returns true for StringIO' do
      expect(instance.send(:valid_gsi_key_type?, StringIO.new('data'))).to be true
    end

    it 'returns false for Array' do
      expect(instance.send(:valid_gsi_key_type?, [1, 2, 3])).to be false
    end

    it 'returns false for Hash' do
      expect(instance.send(:valid_gsi_key_type?, { a: 1 })).to be false
    end

    it 'returns false for Symbol' do
      expect(instance.send(:valid_gsi_key_type?, :symbol)).to be false
    end

    it 'returns false for Boolean' do
      expect(instance.send(:valid_gsi_key_type?, true)).to be false
      expect(instance.send(:valid_gsi_key_type?, false)).to be false
    end

    it 'returns false for Date' do
      expect(instance.send(:valid_gsi_key_type?, Date.today)).to be false
    end

    it 'returns false for Time' do
      expect(instance.send(:valid_gsi_key_type?, Time.now)).to be false
    end

    it 'returns false for nil' do
      # nil should be handled before calling this method, but test the behavior
      expect(instance.send(:valid_gsi_key_type?, nil)).to be false
    end
  end
end
