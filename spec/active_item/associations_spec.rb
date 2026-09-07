# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Associations do
  let(:dynamo_client) { @dynamo_client }

  let(:author_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-authors"
      attr_accessor :name

      def self.name
        'Author'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:book_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-books"
      attr_accessor :title, :author_id

      belongs_to :author, class_name: 'Author', optional: true

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  describe 'belongs_to' do
    it 'defines foreign key accessor' do
      book = book_class.new(title: 'Test', author_id: 'auth-1')
      expect(book.author_id).to eq('auth-1')
    end

    it 'loads associated record' do
      stub_const('Author', author_class)
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-authors", item: { 'id' => 'auth-1', 'name' => 'Hemingway' })

      book = book_class.new(title: 'Test', author_id: 'auth-1')
      author = book.author
      expect(author).not_to be_nil
      expect(author.name).to eq('Hemingway')
    end

    it 'returns nil when foreign key is nil' do
      book = book_class.new(title: 'Test')
      expect(book.author).to be_nil
    end

    describe 'auto-index registration' do
      it 'registers a conventional index from belongs_to' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-comments"
          belongs_to :post

          def self.name
            'Comment'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include('PostIndex' => { partition_key: 'postId' })
      end

      it 'registers indexes for multiple belongs_to associations' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-authorings"
          belongs_to :book
          belongs_to :author

          def self.name
            'Authoring'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include(
          'BookIndex' => { partition_key: 'bookId' },
          'AuthorIndex' => { partition_key: 'authorId' }
        )
      end

      it 'suppresses index with index: false' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-logs"
          belongs_to :user, index: false

          def self.name
            'Log'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes.keys).not_to include('UserIndex')
      end

      it 'uses custom index name with index: "CustomName"' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-items"
          belongs_to :owner, class_name: 'User', index: 'OwnerLookup'

          def self.name
            'Item'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include('OwnerLookup' => { partition_key: 'ownerId' })
        expect(klass.indexes.keys).not_to include('OwnerIndex')
      end

      it 'explicit indexes() takes priority over auto-registered' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-tasks"
          belongs_to :project

          indexes(
            'ProjectIndex' => { partition_key: 'project_id', sort_key: 'created_at' }
          )

          def self.name
            'Task'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes['ProjectIndex']).to eq(partition_key: 'project_id', sort_key: 'created_at')
      end

      it 'works with has_many index auto-detection on the parent' do
        child_class = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-children"
          belongs_to :parent

          def self.name
            'Child'
          end
        end
        child_class.dynamodb = dynamo_client
        stub_const('Child', child_class)

        parent_klass = Class.new(ActiveItem::Base) do
          def self.name
            'Parent'
          end

          self.table_name = "#{TABLE_PREFIX}-parents"
          has_many :children
        end
        parent_klass.dynamodb = dynamo_client

        # Child should have ParentIndex auto-registered
        expect(child_class.indexes).to include('ParentIndex' => { partition_key: 'parentId' })

        # Parent.has_many should be able to resolve the index via detect_index_for_conditions
        parent = parent_klass.new
        parent.save
        relation = parent.children
        expect(relation).to be_a(ActiveItem::Relation)
      end
    end
  end

  describe 'has_many' do
    let(:parent_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-parents"
        attr_accessor :name

        has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'

        def self.name
          'Parent'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    let(:child_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-children"
        attr_accessor :parent_id, :label

        belongs_to :parent, class_name: 'Parent', optional: true

        def self.name
          'Child'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      stub_const('Child', child_class)
      stub_const('Parent', parent_class)
    end

    it 'returns a Relation' do
      parent = parent_class.new(name: 'Test')
      parent.save

      result = parent.children
      expect(result).to be_a(ActiveItem::Relation)
    end

    describe '#build' do
      it 'returns an unsaved record with the foreign key set' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.build(label: 'built-child')
        expect(child).to be_a(child_class)
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('built-child')
        expect(child.id).to be_nil
      end
    end

    describe '#create' do
      it 'saves the record and returns it' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.create(label: 'created-child')
        expect(child.id).not_to be_nil
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('created-child')
      end
    end

    describe '#create!' do
      it 'saves the record and returns it' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.create!(label: 'created-bang-child')
        expect(child.id).not_to be_nil
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('created-bang-child')
      end
    end

    describe '#find (scoped to association)' do
      it 'returns the record when it belongs to the association' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = child_class.new(parent_id: parent.id, label: 'mine')
        child.save

        found = parent.children.find(child.id)
        expect(found.id).to eq(child.id)
        expect(found.label).to eq('mine')
        expect(found.parent_id).to eq(parent.id)
      end

      it 'raises RecordNotFound when record exists but belongs to different parent' do
        parent1 = parent_class.new(name: 'Parent 1')
        parent1.save
        parent2 = parent_class.new(name: 'Parent 2')
        parent2.save

        child = child_class.new(parent_id: parent2.id, label: 'belongs-to-p2')
        child.save

        expect { parent1.children.find(child.id) }.to raise_error(ActiveItem::RecordNotFound)
      end

      it 'raises RecordNotFound when record does not exist' do
        parent = parent_class.new(name: 'Test')
        parent.save

        expect { parent.children.find('nonexistent-id') }.to raise_error(ActiveItem::RecordNotFound)
      end

      it 'still supports block form (Enumerable#find)' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child1 = child_class.new(parent_id: parent.id, label: 'first')
        child1.save
        child2 = child_class.new(parent_id: parent.id, label: 'target')
        child2.save

        found = parent.children.find { |c| c.label == 'target' }
        expect(found.id).to eq(child2.id)
      end
    end
  end

  describe 'validates_associated' do
    let(:validated_child_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-children"
        attr_accessor :parent_id, :label

        validates :label, presence: true

        belongs_to :parent, class_name: 'ValidatedParent', optional: true

        def self.name
          'Child'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    let(:validated_parent_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-parents"
        attr_accessor :name

        has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'
        validates_associated :children

        def self.name
          'ValidatedParent'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      stub_const('Child', validated_child_class)
      stub_const('ValidatedParent', validated_parent_class)
    end

    it 'is valid when no associated records are loaded' do
      parent = validated_parent_class.new(name: 'Test')
      expect(parent).to be_valid
    end

    it 'is valid when loaded associated records are all valid' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      child = validated_child_class.new(parent_id: parent.id, label: 'good')
      child.save

      relation = ActiveItem::Relation.new(nil, preloaded_records: [child], class_name: 'Child')
      allow(parent).to receive(:children).and_return(relation)

      expect(parent).to be_valid
    end

    it 'is invalid when a loaded associated record is invalid' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      invalid_child = validated_child_class.new(parent_id: parent.id, label: '')

      relation = ActiveItem::Relation.new(nil, preloaded_records: [invalid_child], class_name: 'Child')
      allow(parent).to receive(:children).and_return(relation)

      expect(parent).not_to be_valid
      expect(parent.errors[:children]).to include('is invalid')
    end

    it 'adds only one error even when multiple children are invalid' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      first_invalid = validated_child_class.new(parent_id: parent.id, label: '')
      second_invalid = validated_child_class.new(parent_id: parent.id, label: '')

      relation = ActiveItem::Relation.new(nil, preloaded_records: [first_invalid, second_invalid], class_name: 'Child')
      allow(parent).to receive(:children).and_return(relation)

      expect(parent).not_to be_valid
      expect(parent.errors[:children].length).to eq(1)
    end

    it 'is invalid when at least one child among many is invalid' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      valid_child = validated_child_class.new(parent_id: parent.id, label: 'good')
      invalid_child = validated_child_class.new(parent_id: parent.id, label: '')

      relation = ActiveItem::Relation.new(nil, preloaded_records: [valid_child, invalid_child], class_name: 'Child')
      allow(parent).to receive(:children).and_return(relation)

      expect(parent).not_to be_valid
      expect(parent.errors[:children]).to include('is invalid')
    end

    it 'does not fail when association is unloaded (graceful fallback)' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      # Even with invalid children in DB, unloaded association means no validation error
      dynamo_client.put_item(
        table_name: "#{TABLE_PREFIX}-children",
        item: { 'id' => 'bad-child', 'parentId' => parent.id, 'label' => '' }
      )

      expect(parent).to be_valid
    end

    it 'prevents save when associated records are invalid' do
      parent = validated_parent_class.new(name: 'Test')
      parent.save

      invalid_child = validated_child_class.new(parent_id: parent.id, label: '')
      relation = ActiveItem::Relation.new(nil, preloaded_records: [invalid_child], class_name: 'Child')
      allow(parent).to receive(:children).and_return(relation)

      expect(parent.save).to be false
    end
  end

  describe 'accepts_nested_attributes_for' do
    let(:nested_child_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-children"
        attr_accessor :parent_id, :label

        belongs_to :parent, class_name: 'NestedParent', optional: true

        def self.name
          'Child'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    let(:nested_parent_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-parents"
        attr_accessor :name

        has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'
        accepts_nested_attributes_for :children

        def self.name
          'NestedParent'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      stub_const('Child', nested_child_class)
      stub_const('NestedParent', nested_parent_class)
    end

    it 'creates child records when saving parent with nested attributes' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      parent.children_attributes = [
        { label: 'child-1' },
        { label: 'child-2' }
      ]
      parent.save

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(2)
      labels = scan.items.map { |i| i['label'] }
      expect(labels).to contain_exactly('child-1', 'child-2')
    end

    it 'sets the foreign key on child records' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      parent.children_attributes = [{ label: 'auto-fk' }]
      parent.save

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(1)
      expect(scan.items.first['parentId']).to eq(parent.id)
    end

    it 'accepts hash-style attributes (keyed by index)' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      parent.children_attributes = { '0' => { label: 'hash-1' }, '1' => { label: 'hash-2' } }
      parent.save

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(2)
      labels = scan.items.map { |i| i['label'] }
      expect(labels).to contain_exactly('hash-1', 'hash-2')
    end

    it 'handles string keys in attributes' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      parent.children_attributes = [{ 'label' => 'string-key' }]
      parent.save

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(1)
      expect(scan.items.first['label']).to eq('string-key')
    end

    it 'does not create children when parent save fails validation' do
      validated_parent = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-parents"
        attr_accessor :name

        validates :name, presence: true
        has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'
        accepts_nested_attributes_for :children

        def self.name
          'NestedParent'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }

      parent = validated_parent.new(name: '')
      parent.children_attributes = [{ label: 'orphan' }]
      parent.save

      scan = dynamo_client.scan(table_name: "#{TABLE_PREFIX}-children")
      expect(scan.items).to be_empty
    end

    it 'clears nested attributes after successful save (no duplicate creation)' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      parent.children_attributes = [{ label: 'once' }]
      parent.save
      parent.save # second save should not re-create

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(1)
    end

    it 'updates existing child records when id is present' do
      parent = nested_parent_class.new(name: 'Test')
      parent.save

      child = nested_child_class.new(parent_id: parent.id, label: 'original')
      child.save

      parent.children_attributes = [{ id: child.id, label: 'updated' }]
      parent.save

      scan = dynamo_client.scan(
        table_name: "#{TABLE_PREFIX}-children",
        filter_expression: 'parentId = :pid',
        expression_attribute_values: { ':pid' => parent.id }
      )
      expect(scan.items.length).to eq(1)
      expect(scan.items.first['label']).to eq('updated')
    end

    context 'with allow_destroy: true' do
      let(:destroyable_parent_class) do
        Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-parents"
          attr_accessor :name

          has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'
          accepts_nested_attributes_for :children, allow_destroy: true

          def self.name
            'NestedParent'
          end
        end.tap { |klass| klass.dynamodb = dynamo_client }
      end

      it 'destroys child records when _destroy is true' do
        parent = destroyable_parent_class.new(name: 'Test')
        parent.save

        child = nested_child_class.new(parent_id: parent.id, label: 'doomed')
        child.save

        parent.children_attributes = [{ id: child.id, _destroy: true }]
        parent.save

        scan = dynamo_client.scan(
          table_name: "#{TABLE_PREFIX}-children",
          filter_expression: 'parentId = :pid',
          expression_attribute_values: { ':pid' => parent.id }
        )
        expect(scan.items).to be_empty
      end

      it 'can mix create, update, and destroy in one save' do
        parent = destroyable_parent_class.new(name: 'Test')
        parent.save

        existing = nested_child_class.new(parent_id: parent.id, label: 'keep')
        existing.save
        doomed = nested_child_class.new(parent_id: parent.id, label: 'remove')
        doomed.save

        parent.children_attributes = [
          { id: existing.id, label: 'kept-updated' },
          { id: doomed.id, _destroy: true },
          { label: 'brand-new' }
        ]
        parent.save

        scan = dynamo_client.scan(
          table_name: "#{TABLE_PREFIX}-children",
          filter_expression: 'parentId = :pid',
          expression_attribute_values: { ':pid' => parent.id }
        )
        labels = scan.items.map { |i| i['label'] }
        expect(labels).to contain_exactly('kept-updated', 'brand-new')
      end
    end

    context 'without allow_destroy (default)' do
      it 'ignores _destroy flag and updates the record instead' do
        parent = nested_parent_class.new(name: 'Test')
        parent.save

        child = nested_child_class.new(parent_id: parent.id, label: 'survivor')
        child.save

        parent.children_attributes = [{ id: child.id, _destroy: true }]
        parent.save

        scan = dynamo_client.scan(
          table_name: "#{TABLE_PREFIX}-children",
          filter_expression: 'parentId = :pid',
          expression_attribute_values: { ':pid' => parent.id }
        )
        expect(scan.items.length).to eq(1)
        expect(scan.items.first['label']).to eq('survivor')
      end
    end
  end
end
