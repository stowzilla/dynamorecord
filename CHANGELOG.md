# Changelog

## 0.0.22

### Changed

- **Scoped `find` on associations** — `Relation#find(id)` now enforces association scope, matching Rails behavior. When called on an association (e.g., `@project.epics.find(id)`), it validates that the found record belongs to the association before returning it. If the record exists but belongs to a different parent, `ActiveItem::RecordNotFound` is raised. This prevents accidentally accessing records outside the association scope.

  ```ruby
  # Before: would return the epic even if it belonged to a different project
  @project.epics.find(epic_id)

  # After: raises RecordNotFound if epic.project_id != @project.id
  @project.epics.find(epic_id)
  ```

## 0.0.21

### Added

- **GSI key type validation** — ActiveItem now validates that Global Secondary Index (GSI) key attributes have valid DynamoDB types at write time. Valid types are: String (non-empty), Numeric (Integer, Float, BigDecimal), and Binary (StringIO). Invalid types (Array, Hash, Boolean, Symbol, Date, Time, empty strings) now raise `ActiveItem::InvalidGsiKeyTypeError` immediately, with a helpful error message identifying the attribute and index. This catches common bugs like passing `Date.today` instead of `date.to_s`, or accidentally setting an array where a string was expected.

  ```ruby
  # Raises InvalidGsiKeyTypeError: Item#status has invalid type Array for GSI 'StatusIndex'
  item = Item.new(status: ['a', 'b', 'c'])
  item.save

  # Raises InvalidGsiKeyTypeError for empty strings
  item = Item.new(status: '')
  item.save
  ```

## 0.0.19

### Added

- **`validates_associated`** — Validates that associated records (loaded via `has_many`) are valid before saving the parent. Only checks in-memory/loaded records — does not trigger DB queries for unloaded associations.

- **`accepts_nested_attributes_for`** — Define nested attribute writers for has_many associations. Supports create, update, and destroy of child records through the parent's save. Nested saves are now wrapped in a DynamoDB transaction for atomicity — if any child operation fails, none are committed.

  ```ruby
  class Conversation < ActiveItem::Base
    has_many :messages
    accepts_nested_attributes_for :messages, allow_destroy: true
  end

  conversation.messages_attributes = [
    { role: 'user', body: 'Hello' },
    { id: 'msg-1', body: 'Updated text' },
    { id: 'msg-2', _destroy: true }
  ]
  conversation.save  # atomic: all children created/updated/destroyed together
  ```

- **`Relation#loaded?`** — Check whether a has_many relation's records have been loaded into memory.

## 0.0.18

### Added

- **Transactional saves** — `save`, `save!`, `destroy`, and `destroy!` now automatically enroll in the current transaction when called inside a `Model.transaction` block. This enables an ActiveRecord-style implicit API:

  ```ruby
  Model.transaction do
    record1.save!
    record2.save!
    record3.destroy!
  end
  ```

  All operations are committed atomically at block end. The explicit API (`txn.put(record)`) continues to work for backwards compatibility.

- **RecordInvalid exception** — `save!` now raises `ActiveItem::RecordInvalid` with the record attached, instead of a generic `StandardError`. This matches ActiveRecord behavior.

- **Transaction.active?** — class method to check if code is executing inside a transaction block.

## 0.0.13

### Changed

- **Configuration defaults from ENV** — `table_prefix` now defaults to `ENV['APP_NAME']` and `environment` defaults to `ENV['ENVIRONMENT']` instead of `nil`. Explicit `.configure` calls still override. This eliminates the boilerplate `ActiveItem.configure` block in most Belt apps.

## 0.0.9

### Fixed

- **Pagination cursor loss in `paginated_query_with_index`** — when the 2x overfetch returned all remaining items in a single DynamoDB response (no `LastEvaluatedKey`), the method returned `has_more: false` despite having silently trimmed items. Now builds a synthetic `ExclusiveStartKey` from the last returned item's attributes (table PK + GSI partition/sort keys) to ensure correct pagination.

## 0.0.8

### Added

- **Array partition key fan-out** — `where(partition_key: [val1, val2, ...])` now queries each partition in parallel and merges results, instead of raising `ArgumentError`
- Works with `.to_a`, `.page(cursor, per_page:)`, `.count`, `.order(:desc)`, `.not(...)`, and all other chainable methods
- Pagination uses a `sort_val|id` cursor format for cross-partition consistency
- Thread-pooled execution (max 10 concurrent queries) matching existing `preload_has_many_counts` pattern

## 0.0.7

### Added

- `destroy!` — raises `ActiveItem::RecordNotDestroyed` when the record cannot be destroyed (e.g., callbacks halt the chain)

## 0.0.6

### Added

- `Model.destroy_all` — class-level method that scans the table and calls `destroy` on each record (runs callbacks)
- `Model.delete_all` — class-level method that scans the table and calls `delete` on each record (skips callbacks)

### Fixed

- `delete_all` now correctly skips callbacks (was previously delegating to `destroy_all`)

## 0.0.5

### Fixed

- Fix RuboCop offenses: merge nested conditional in `Base`, remove trailing newline in `version.rb`

### Infrastructure

- Fix CI workflow to trigger on `master` branch (was incorrectly set to `main`)
- Add bundler-audit security scanning to CI pipeline
- Add gem signing with certificate chain for consumer verification

## 0.0.4

### Fixed

- Fix `attribute_was` calling `attribute_in_database` (ActiveRecord-only) — now uses `changed_attributes` from ActiveModel::Dirty

## 0.0.3

### Changed

- Replace custom `validates_length_of`, `validates_numericality_of`, `validates_format_of` with ActiveModel built-ins
- Replace hand-rolled dirty tracking (`@pending_changes`/`@previously_changed`) with `ActiveModel::Dirty`
- Replace manual `ActiveSupport::Callbacks` DSL with `ActiveModel::Callbacks` + `define_model_callbacks`

### Improved

- Add `limit` to `UniquenessValidator` queries (limit 2 when excluding self, `.first` for new records)
- `execute_count_query` now respects `limit_value` and short-circuits pagination
- `check_dependent_associations` uses `limit(1).any?` for restrict checks

## 0.0.2

### Security

- **[Critical]** Pagination cursor validation — decoded JSON is now validated to only contain flat key/value pairs with alphanumeric keys and string/numeric values. Prevents partition traversal via crafted cursors.
- **[Critical]** Remove arbitrary file require from `model_loader.rb` — `safe_constantize_model` now uses `safe_constantize` with class name format validation instead of requiring files from disk.
- **[Medium]** Add jitter to exponential backoff in batch operations to prevent thundering herd.
- **[Low]** Replace `Object.const_get` with `safe_constantize` in `composed_of` to prevent constant hierarchy traversal.

### Fixed

- Fix `set_created_timestamp` callback not setting `@created_at`, causing DynamoDB `Invalid attribute value type` errors on create
- Fix duplicate `id=` method definition (Lint/DuplicateMethods) by using `attr_reader :id` with a custom setter
- Fix duplicate `last` method definition in QueryHelpers
- Fix duplicate branch in Relation `includes` case statement (Lint/DuplicateBranch)
- Use `Comparable#clamp` in Pagination and Relation (Style/ComparableClamp)

### Added

- Documentation comments for all public modules and classes (Style/Documentation)
- `--workdir` option to CI DynamoDB service for `act` compatibility

## 0.0.1

- Initial release
- Core ORM: find, save, create, update, destroy
- Chainable query builder (Relation) with where, not, limit, order, select
- Associations: has_many, belongs_to with dependent options
- Callbacks: before/after save, create, update, destroy, validation
- Dirty tracking: attribute_changed?, changes, previous_changes
- Validations: uniqueness, length, numericality, format (via ActiveModel)
- Transactions: TransactWriteItems and TransactGetItems
- Pagination: cursor-based with PaginatedResult
- Composed of: value object aggregation
- Batch operations: batch_find, batch_write
- Configurable table naming, logger, and DynamoDB client
