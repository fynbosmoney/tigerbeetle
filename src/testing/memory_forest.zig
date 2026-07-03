const std = @import("std");
const assert = std.debug.assert;

const constants = @import("../constants.zig");
const Direction = @import("../direction.zig").Direction;
const TimestampRange = @import("../lsm/timestamp_range.zig").TimestampRange;
const ScopeCloseMode = @import("../lsm/tree.zig").ScopeCloseMode;
const snapshot_latest = @import("../lsm/tree.zig").snapshot_latest;
const ScanBuffer = @import("../lsm/scan_buffer.zig").ScanBuffer;

pub const EvaluateNext = @import("../lsm/scan_range.zig").EvaluateNext;
pub const ScanLookupStatus = @import("../lsm/scan_lookup.zig").ScanLookupStatus;

pub const Backend = struct {
    pub const GridType = MemoryGridType;
    pub const GrooveType = MemoryGrooveType;
    pub const ScanLookupType = MemoryScanLookupType;
    pub const ScanRangeType = MemoryScanRangeType;
    pub const ScanTreeType = MemoryScanTreeType;
    pub const ForestType = MemoryForestType;
};

pub fn MemoryGridType(comptime Storage: type) type {
    _ = Storage;
    return struct {
        const Grid = @This();

        pub const NextTick = struct {};

        superblock: struct { replica_index: ?u8 = null } = .{},
        next_tick_callback: ?*const fn (*NextTick) void = null,
        next_tick_context: ?*NextTick = null,

        pub fn on_next_tick(
            grid: *Grid,
            callback: *const fn (*NextTick) void,
            context: *NextTick,
        ) void {
            assert(grid.next_tick_callback == null);
            grid.next_tick_callback = callback;
            grid.next_tick_context = context;
        }

        pub fn run_next_tick(grid: *Grid) bool {
            const callback = grid.next_tick_callback orelse return false;
            const context = grid.next_tick_context.?;
            grid.next_tick_callback = null;
            grid.next_tick_context = null;
            callback(context);
            return true;
        }
    };
}

fn index_prefix_type(comptime Index: type) type {
    return switch (@typeInfo(Index)) {
        .void => void,
        .int => Index,
        .@"enum" => |info| info.tag_type,
        else => @compileError("unsupported mock index type: " ++ @typeName(Index)),
    };
}

fn derived_index_type(comptime function: anytype) type {
    const return_type = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    return @typeInfo(return_type).optional.child;
}

fn field_is_ignored(comptime config: anytype, comptime name: []const u8) bool {
    if (std.mem.eql(u8, name, "id") or std.mem.eql(u8, name, "timestamp")) return true;
    for (config.ignored) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

fn field_is_optional(comptime config: anytype, comptime name: []const u8) bool {
    for (config.optional) |optional| {
        if (std.mem.eql(u8, name, optional)) return true;
    }
    return false;
}

fn MemoryIndexType(comptime Index: type) type {
    const Prefix = index_prefix_type(Index);
    return struct {
        const MemoryIndex = @This();

        pub const Table = struct {
            pub const Value = struct {
                field: Prefix,
                timestamp: u64,
            };
            pub const Key = Value;

            pub inline fn key_from_value(value: *const Value) Key {
                return value.*;
            }
        };

        // Records the mutations performed while a scope is open, so `.discard` can undo them
        // without cloning the whole index. This mirrors the real tree/cache-map scope, which
        // rolls back in-scope changes rather than snapshotting the entire structure.
        const Undo = struct {
            value: Table.Value,
            // The operation required to undo the logged mutation.
            operation: enum { insert, remove },
        };

        allocator: std.mem.Allocator,
        values: std.ArrayListUnmanaged(Table.Value) = .{},
        scope: ?std.ArrayListUnmanaged(Undo) = null,

        fn init(allocator: std.mem.Allocator) MemoryIndex {
            return .{ .allocator = allocator };
        }

        fn deinit(index: *MemoryIndex) void {
            index.values.deinit(index.allocator);
            if (index.scope) |*scope| scope.deinit(index.allocator);
        }

        fn reset(index: *MemoryIndex) void {
            index.values.clearRetainingCapacity();
            if (index.scope) |*scope| scope.deinit(index.allocator);
            index.scope = null;
        }

        inline fn less_than(_: void, a: Table.Value, b: Table.Value) bool {
            return switch (@typeInfo(Prefix)) {
                .void => a.timestamp < b.timestamp,
                .int => a.field < b.field or
                    (a.field == b.field and a.timestamp < b.timestamp),
                else => comptime unreachable,
            };
        }

        // The first index whose value is not less than `value` (binary-search lower bound).
        // `values` is kept sorted so that range scans can rely on the ordering and so that
        // insert/remove are logarithmic in comparisons rather than a full re-sort per mutation.
        fn lower_bound(index: *const MemoryIndex, value: Table.Value) usize {
            var low: usize = 0;
            var high: usize = index.values.items.len;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (less_than({}, index.values.items[mid], value)) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            return low;
        }

        // Insert/erase keeping `values` sorted, without touching the scope log.
        fn insert(index: *MemoryIndex, value: Table.Value) void {
            const i = index.lower_bound(value);
            assert(i == index.values.items.len or
                !std.meta.eql(index.values.items[i], value));
            index.values.insert(index.allocator, i, value) catch @panic("out of memory");
        }

        fn erase(index: *MemoryIndex, value: Table.Value) void {
            const i = index.lower_bound(value);
            assert(i < index.values.items.len and
                std.meta.eql(index.values.items[i], value));
            _ = index.values.orderedRemove(i);
        }

        fn log(index: *MemoryIndex, undo: Undo) void {
            if (index.scope) |*scope| {
                scope.append(index.allocator, undo) catch @panic("out of memory");
            }
        }

        pub fn put(index: *MemoryIndex, value: *const Table.Value) void {
            index.insert(value.*);
            index.log(.{ .value = value.*, .operation = .remove });
        }

        pub fn remove(index: *MemoryIndex, value: *const Table.Value) void {
            index.erase(value.*);
            index.log(.{ .value = value.*, .operation = .insert });
        }

        fn scope_open(index: *MemoryIndex) void {
            assert(index.scope == null);
            index.scope = .{};
        }

        fn scope_close(index: *MemoryIndex, mode: ScopeCloseMode) void {
            var scope = index.scope orelse unreachable;
            index.scope = null; // Detach so replayed ops below don't re-log.
            defer scope.deinit(index.allocator);

            if (mode == .discard) {
                var i: usize = scope.items.len;
                while (i > 0) {
                    i -= 1;
                    switch (scope.items[i].operation) {
                        .insert => index.insert(scope.items[i].value),
                        .remove => index.erase(scope.items[i].value),
                    }
                }
            }
        }
    };
}

fn MemoryObjectTreeType(comptime Object: type) type {
    return struct {
        const ObjectTree = @This();
        const KeyRange = struct { key_max: u64 = 0 };
        pub const Table = struct {
            pub const Value = Object;
        };

        // Records the mutations performed while a scope is open, so `.discard` can undo them
        // without cloning the whole object map (see `MemoryIndex.Undo`).
        const Undo = union(enum) {
            // Undo a fresh insert by removing the key.
            remove: u64,
            // Undo an overwrite by restoring the previous object.
            restore: Object,
        };

        allocator: std.mem.Allocator,
        map: std.AutoHashMapUnmanaged(u64, Object) = .{},
        key_range: ?KeyRange = null,
        scope: ?std.ArrayListUnmanaged(Undo) = null,
        // `key_range` never shrinks on remove, so a single saved copy restores it on discard.
        scope_key_range: ?KeyRange = null,

        fn init(allocator: std.mem.Allocator) ObjectTree {
            return .{ .allocator = allocator };
        }

        fn deinit(tree: *ObjectTree) void {
            tree.map.deinit(tree.allocator);
            if (tree.scope) |*scope| scope.deinit(tree.allocator);
        }

        fn reset(tree: *ObjectTree) void {
            tree.map.clearRetainingCapacity();
            tree.key_range = null;
            if (tree.scope) |*scope| scope.deinit(tree.allocator);
            tree.scope = null;
            tree.scope_key_range = null;
        }

        // Insert or overwrite `object` (keyed by timestamp), maintaining `key_range` and the
        // scope undo log.
        fn put(tree: *ObjectTree, object: *const Object) void {
            const previous = tree.map.fetchPut(tree.allocator, object.timestamp, object.*) catch
                @panic("out of memory");
            if (tree.scope) |*scope| {
                scope.append(tree.allocator, if (previous) |kv|
                    .{ .restore = kv.value }
                else
                    .{ .remove = object.timestamp }) catch @panic("out of memory");
            }
            if (tree.key_range) |*key_range| {
                key_range.key_max = @max(key_range.key_max, object.timestamp);
            } else {
                tree.key_range = .{ .key_max = object.timestamp };
            }
        }

        fn scope_open(tree: *ObjectTree) void {
            assert(tree.scope == null);
            tree.scope = .{};
            tree.scope_key_range = tree.key_range;
        }

        fn scope_close(tree: *ObjectTree, mode: ScopeCloseMode) void {
            var scope = tree.scope orelse unreachable;
            tree.scope = null;
            defer scope.deinit(tree.allocator);

            if (mode == .discard) {
                var i: usize = scope.items.len;
                while (i > 0) {
                    i -= 1;
                    switch (scope.items[i]) {
                        .remove => |timestamp| assert(tree.map.remove(timestamp)),
                        .restore => |object| tree.map.put(
                            tree.allocator,
                            object.timestamp,
                            object,
                        ) catch @panic("out of memory"),
                    }
                }
                tree.key_range = tree.scope_key_range;
            }
            tree.scope_key_range = null;
        }
    };
}

pub fn MemoryGrooveType(
    comptime Storage: type,
    comptime Object: type,
    comptime groove_config: anytype,
) type {
    _ = Storage;
    const has_id = @hasField(Object, "id");
    const PrimaryKey = if (has_id) u128 else u64;
    const ObjectTreeImpl = MemoryObjectTreeType(Object);

    comptime var index_fields: []const std.builtin.Type.StructField = &.{};
    for (std.meta.fields(Object)) |field| {
        if (!field_is_ignored(groove_config, field.name)) {
            const Tree = MemoryIndexType(field.type);
            index_fields = index_fields ++ [_]std.builtin.Type.StructField{.{
                .name = field.name,
                .type = Tree,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(Tree),
            }};
        }
    }
    for (std.meta.fields(@TypeOf(groove_config.derived))) |field| {
        const Tree = MemoryIndexType(derived_index_type(@field(groove_config.derived, field.name)));
        index_fields = index_fields ++ [_]std.builtin.Type.StructField{.{
            .name = field.name,
            .type = Tree,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Tree),
        }};
    }
    const IndexTreesImpl = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = index_fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    const TreeOptions = struct { batch_value_count_limit: u32 };
    comptime var option_fields: [index_fields.len]std.builtin.Type.StructField = undefined;
    for (index_fields, 0..) |field, i| option_fields[i] = .{
        .name = field.name,
        .type = TreeOptions,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(TreeOptions),
    };
    const IndexTreeOptionsImpl = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &option_fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    const Helper = struct {
        fn Type(comptime field_name: []const u8) type {
            const is_derived = @hasField(@TypeOf(groove_config.derived), field_name);
            const IndexImpl = if (is_derived)
                derived_index_type(@field(groove_config.derived, field_name))
            else
                @FieldType(Object, field_name);
            return struct {
                pub const Index = IndexImpl;
                pub const IndexPrefix = index_prefix_type(IndexImpl);

                pub fn index_from_object(object: *const Object) ?IndexPrefix {
                    if (is_derived) {
                        const value = @field(groove_config.derived, field_name)(object) orelse
                            return null;
                        return switch (@typeInfo(IndexImpl)) {
                            .void => {},
                            .int => value,
                            .@"enum" => @intFromEnum(value),
                            else => unreachable,
                        };
                    }
                    const value = @field(object, field_name);
                    const prefix: IndexPrefix = switch (@typeInfo(IndexImpl)) {
                        .void => {},
                        .int => value,
                        .@"enum" => @intFromEnum(value),
                        else => unreachable,
                    };
                    if (field_is_optional(groove_config, field_name) and prefix == 0) return null;
                    return prefix;
                }
            };
        }
    }.Type;

    return struct {
        const Groove = @This();

        pub const ObjectTree = ObjectTreeImpl;
        pub const IndexTrees = IndexTreesImpl;
        pub const IndexTreeOptions = IndexTreeOptionsImpl;
        pub const IndexTreeFieldHelperType = Helper;
        pub const config = groove_config;
        pub const LookupResult = union(enum) { found_object: Object, found_orphaned_id, not_found };
        pub const PrefetchContext = struct { alignment: u128 = 0 };
        pub const ScanBuilder = MemoryScanBuilderType(Groove);
        pub const Options = struct {
            prefetch_entries_for_read_max: u32,
            prefetch_entries_for_update_max: u32,
            cache_entries_max: u32,
            tree_options_object: TreeOptions,
            tree_options_id: if (has_id) TreeOptions else void,
            tree_options_index: IndexTreeOptionsImpl,
        };

        allocator: std.mem.Allocator,
        objects: ObjectTreeImpl,
        ids: if (has_id) std.AutoHashMapUnmanaged(u128, u64) else void,
        // Undo log of ids inserted while a scope is open; `.discard` removes them. Ids are only
        // ever added within a scope (never removed or reassigned), so a list of ids suffices.
        ids_scope: if (has_id) ?std.ArrayListUnmanaged(u128) else void,
        indexes: IndexTreesImpl,
        scan_builder: ScanBuilder,
        // Snapshot captured by `prefetch_setup` and read while prefetch is in flight (e.g. the
        // expiry scan reads `prefetch_snapshot` in state_machine.zig).
        prefetch_snapshot: ?u64 = null,

        fn init(groove: *Groove, allocator: std.mem.Allocator) !void {
            groove.* = .{
                .allocator = allocator,
                .objects = ObjectTreeImpl.init(allocator),
                .ids = if (has_id) .{} else {},
                .ids_scope = if (has_id) null else {},
                .indexes = undefined,
                .scan_builder = undefined,
            };
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                @field(groove.indexes, field.name) = field.type.init(allocator);
            }
            try groove.scan_builder.init(allocator);
        }

        fn deinit(groove: *Groove) void {
            groove.scan_builder.deinit();
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                @field(groove.indexes, field.name).deinit();
            }
            if (has_id) {
                groove.ids.deinit(groove.allocator);
                if (groove.ids_scope) |*scope| scope.deinit(groove.allocator);
            }
            groove.objects.deinit();
        }

        fn reset(groove: *Groove) void {
            groove.scan_builder.reset();
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                @field(groove.indexes, field.name).reset();
            }
            if (has_id) {
                groove.ids.clearRetainingCapacity();
                if (groove.ids_scope) |*scope| scope.deinit(groove.allocator);
                groove.ids_scope = null;
            }
            groove.objects.reset();
        }

        pub fn get(groove: *const Groove, key: PrimaryKey) LookupResult {
            const timestamp = if (has_id) groove.ids.get(key) orelse return .not_found else key;
            if (timestamp == 0) return .found_orphaned_id;
            return if (groove.objects.map.get(timestamp)) |object|
                .{ .found_object = object }
            else
                .not_found;
        }

        pub fn get_by_timestamp(groove: *const Groove, timestamp: u64) LookupResult {
            comptime assert(has_id);
            return if (groove.objects.map.get(timestamp)) |object|
                .{ .found_object = object }
            else
                .not_found;
        }

        pub fn exists(groove: *const Groove, timestamp: u64) bool {
            comptime assert(has_id);
            return groove.objects.map.contains(timestamp);
        }

        pub fn prefetch_setup(groove: *Groove, snapshot: ?u64) void {
            // Mirror the real groove: a null snapshot means "the current snapshot".
            groove.prefetch_snapshot = snapshot orelse snapshot_latest;
        }
        pub fn prefetch_enqueue(_: *Groove, _: PrimaryKey) void {}
        pub fn prefetch_enqueue_by_timestamp(_: *Groove, _: u64) void {}
        pub fn prefetch_exists_enqueue(_: *Groove, _: u64) void {}

        pub fn prefetch(
            _: *Groove,
            callback: *const fn (*PrefetchContext) void,
            context: *PrefetchContext,
        ) void {
            // Everything is already in memory; prefetch completes synchronously. Leave
            // `prefetch_snapshot` set (as the real groove keeps it through the cycle); the next
            // `prefetch_setup` overwrites it.
            callback(context);
        }

        fn indexes_insert(groove: *Groove, object: *const Object) void {
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                const FieldHelper = Helper(field.name);
                if (FieldHelper.index_from_object(object)) |value| {
                    @field(groove.indexes, field.name).put(&.{
                        .field = value,
                        .timestamp = object.timestamp,
                    });
                }
            }
        }

        fn indexes_remove(groove: *Groove, object: *const Object) void {
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                const FieldHelper = Helper(field.name);
                if (FieldHelper.index_from_object(object)) |value| {
                    @field(groove.indexes, field.name).remove(&.{
                        .field = value,
                        .timestamp = object.timestamp,
                    });
                }
            }
        }

        pub fn insert(groove: *Groove, object: *const Object) void {
            assert(TimestampRange.valid(object.timestamp));
            assert(!groove.objects.map.contains(object.timestamp));
            if (has_id) {
                assert(!groove.ids.contains(object.id));
                groove.ids.put(groove.allocator, object.id, object.timestamp) catch
                    @panic("out of memory");
                if (groove.ids_scope) |*scope| {
                    scope.append(groove.allocator, object.id) catch @panic("out of memory");
                }
            }
            groove.objects.put(object);
            groove.indexes_insert(object);
        }

        pub fn update(
            groove: *Groove,
            values: struct { old: *const Object, new: *const Object },
        ) void {
            assert(values.old != values.new);
            assert(values.old.timestamp == values.new.timestamp);
            groove.indexes_remove(values.old);
            groove.indexes_insert(values.new);
            groove.objects.put(values.new);
        }

        pub fn insert_orphaned_id(groove: *Groove, id: u128) void {
            comptime assert(has_id and groove_config.orphaned_ids);
            assert(groove.ids_scope == null);
            assert(!groove.ids.contains(id));
            groove.ids.put(groove.allocator, id, 0) catch @panic("out of memory");
        }

        pub fn scope_open(groove: *Groove) void {
            groove.objects.scope_open();
            if (has_id) {
                assert(groove.ids_scope == null);
                groove.ids_scope = .{};
            }
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                @field(groove.indexes, field.name).scope_open();
            }
        }

        pub fn scope_close(groove: *Groove, mode: ScopeCloseMode) void {
            groove.objects.scope_close(mode);
            if (has_id) {
                var scope = groove.ids_scope orelse unreachable;
                groove.ids_scope = null;
                defer scope.deinit(groove.allocator);

                if (mode == .discard) {
                    for (scope.items) |id| assert(groove.ids.remove(id));
                }
            }
            inline for (std.meta.fields(IndexTreesImpl)) |field| {
                @field(groove.indexes, field.name).scope_close(mode);
            }
        }
    };
}

fn MemoryScanBuilderType(comptime Groove: type) type {
    return struct {
        const ScanBuilder = @This();
        pub const Scan = struct {
            allocator: std.mem.Allocator,
            timestamps: std.ArrayListUnmanaged(u64) = .{},
            cursor: usize = 0,
            // The direction the timestamps are sorted in. Carried explicitly so merges produce
            // output in the query's direction rather than inferring it from the data.
            direction: Direction,

            pub fn next(scan: *Scan) error{ReadAgain}!?u64 {
                if (scan.cursor == scan.timestamps.items.len) return null;
                const timestamp = scan.timestamps.items[scan.cursor];
                scan.cursor += 1;
                return timestamp;
            }

            pub fn finished(scan: *const Scan) bool {
                return scan.cursor == scan.timestamps.items.len;
            }

            fn deinit(scan: *Scan) void {
                scan.timestamps.deinit(scan.allocator);
            }
        };

        allocator: std.mem.Allocator,
        // The real ScanBuilder holds `lsm_scans_max` condition scans plus `lsm_scans_max - 1`
        // merge scans (scan_builder.zig:60-67); the mock keeps both in one array.
        scans: [constants.lsm_scans_max * 2 - 1]Scan = undefined,
        scan_count: usize = 0,

        fn init(builder: *ScanBuilder, allocator: std.mem.Allocator) !void {
            builder.* = .{ .allocator = allocator };
        }

        fn deinit(builder: *ScanBuilder) void {
            builder.reset();
        }

        pub fn reset(builder: *ScanBuilder) void {
            for (builder.scans[0..builder.scan_count]) |*scan| scan.deinit();
            builder.scan_count = 0;
        }

        fn groove(builder: *ScanBuilder) *Groove {
            return @fieldParentPtr("scan_builder", builder);
        }

        fn add(builder: *ScanBuilder, direction: Direction) *Scan {
            assert(builder.scan_count < builder.scans.len);
            const scan = &builder.scans[builder.scan_count];
            builder.scan_count += 1;
            scan.* = .{ .allocator = builder.allocator, .direction = direction };
            return scan;
        }

        fn sort(scan: *Scan) void {
            const Context = struct {
                direction: Direction,
                fn less_than(context: @This(), a: u64, b: u64) bool {
                    return if (context.direction == .ascending) a < b else a > b;
                }
            };
            std.mem.sort(
                u64,
                scan.timestamps.items,
                Context{ .direction = scan.direction },
                Context.less_than,
            );
        }

        pub fn scan_prefix(
            builder: *ScanBuilder,
            comptime index: std.meta.FieldEnum(Groove.IndexTrees),
            _: *const ScanBuffer,
            _: u64,
            prefix: Groove.IndexTreeFieldHelperType(@tagName(index)).IndexPrefix,
            timestamp_range: TimestampRange,
            direction: Direction,
        ) *Scan {
            const scan = builder.add(direction);
            for (@field(builder.groove().indexes, @tagName(index)).values.items) |value| {
                if (std.meta.eql(value.field, prefix) and
                    value.timestamp >= timestamp_range.min and
                    value.timestamp <= timestamp_range.max)
                {
                    scan.timestamps.append(builder.allocator, value.timestamp) catch
                        @panic("out of memory");
                }
            }
            sort(scan);
            return scan;
        }

        pub fn scan_timestamp(
            builder: *ScanBuilder,
            _: *const ScanBuffer,
            _: u64,
            timestamp_range: TimestampRange,
            direction: Direction,
        ) *Scan {
            const scan = builder.add(direction);
            var iterator = builder.groove().objects.map.keyIterator();
            while (iterator.next()) |timestamp| {
                if (timestamp.* >= timestamp_range.min and timestamp.* <= timestamp_range.max) {
                    scan.timestamps.append(builder.allocator, timestamp.*) catch
                        @panic("out of memory");
                }
            }
            sort(scan);
            return scan;
        }

        pub fn merge_union(builder: *ScanBuilder, scans: []const *Scan) *Scan {
            const direction = scans[0].direction;
            const result = builder.add(direction);
            for (scans) |scan| {
                assert(scan.direction == direction);
                for (scan.timestamps.items) |timestamp| {
                    result.timestamps.append(builder.allocator, timestamp) catch
                        @panic("out of memory");
                }
            }
            sort(result);
            // Drop duplicates, which are adjacent after sorting.
            var read: usize = 0;
            var write: usize = 0;
            while (read < result.timestamps.items.len) : (read += 1) {
                if (write == 0 or
                    result.timestamps.items[read] != result.timestamps.items[write - 1])
                {
                    result.timestamps.items[write] = result.timestamps.items[read];
                    write += 1;
                }
            }
            result.timestamps.shrinkRetainingCapacity(write);
            return result;
        }

        pub fn merge_intersection(builder: *ScanBuilder, scans: []const *Scan) *Scan {
            const direction = scans[0].direction;
            const result = builder.add(direction);
            // A timestamp is included iff it appears in every input scan.
            for (scans[0].timestamps.items) |timestamp| {
                var present_in_all = true;
                for (scans[1..]) |scan| {
                    assert(scan.direction == direction);
                    if (std.mem.indexOfScalar(u64, scan.timestamps.items, timestamp) == null) {
                        present_in_all = false;
                        break;
                    }
                }
                if (present_in_all) {
                    result.timestamps.append(builder.allocator, timestamp) catch
                        @panic("out of memory");
                }
            }
            sort(result);
            return result;
        }
    };
}

pub fn MemoryScanLookupType(
    comptime Groove: type,
    comptime Scan: type,
    comptime Storage: type,
) type {
    _ = Storage;
    const Object = Groove.ObjectTree.Table.Value;
    return struct {
        const ScanLookup = @This();
        pub const Callback = *const fn (*ScanLookup, []const Object) void;

        groove: *Groove,
        scan: *Scan,
        state: ScanLookupStatus = .idle,
        // Match the state machine's 16-byte alignment: it stores this in a union field and
        // recovers `*StateMachine` from it via `@fieldParentPtr` (see `MemoryForest`).
        _alignment: [0]u128 = .{},

        pub fn init(groove: *Groove, scan: *Scan) ScanLookup {
            return .{ .groove = groove, .scan = scan };
        }

        pub fn read(self: *ScanLookup, buffer: []Object, callback: Callback) void {
            var count: usize = 0;
            while (count < buffer.len) {
                const timestamp = self.scan.next() catch unreachable orelse break;
                buffer[count] = self.groove.objects.map.get(timestamp).?;
                count += 1;
            }
            self.state = if (count == buffer.len and !self.scan.finished())
                .buffer_finished
            else
                .scan_finished;
            callback(self, buffer[0..count]);
        }
    };
}

pub fn MemoryScanRangeType(
    comptime Tree: type,
    comptime Storage: type,
    comptime EvaluatorContext: type,
    comptime value_next: fn (
        context: EvaluatorContext,
        value: *const Tree.Table.Value,
    ) callconv(.@"inline") EvaluateNext,
    comptime timestamp_from_value: fn (
        context: EvaluatorContext,
        value: *const Tree.Table.Value,
    ) callconv(.@"inline") u64,
) type {
    _ = Storage;
    return struct {
        const ScanRange = @This();

        evaluator_context: EvaluatorContext,
        tree: *Tree,
        snapshot_value: u64,
        direction: Direction,
        cursor: usize,
        stopped: bool = false,

        pub fn init(
            evaluator_context: EvaluatorContext,
            tree: *Tree,
            _: *const ScanBuffer,
            snapshot_: u64,
            _: Tree.Table.Key,
            _: Tree.Table.Key,
            direction: Direction,
        ) ScanRange {
            return .{
                .evaluator_context = evaluator_context,
                .tree = tree,
                .snapshot_value = snapshot_,
                .direction = direction,
                .cursor = if (direction == .ascending) 0 else tree.values.items.len,
            };
        }

        pub fn next(scan: *ScanRange) error{ReadAgain}!?u64 {
            const context = scan.evaluator_context;
            while (!scan.stopped) {
                const value = if (scan.direction == .ascending) blk: {
                    if (scan.cursor == scan.tree.values.items.len) return null;
                    const value = &scan.tree.values.items[scan.cursor];
                    scan.cursor += 1;
                    break :blk value;
                } else blk: {
                    if (scan.cursor == 0) return null;
                    scan.cursor -= 1;
                    break :blk &scan.tree.values.items[scan.cursor];
                };
                switch (value_next(context, value)) {
                    .include_and_continue => return timestamp_from_value(context, value),
                    .include_and_stop => {
                        scan.stopped = true;
                        return timestamp_from_value(context, value);
                    },
                    .exclude_and_continue => continue,
                    .exclude_and_stop => {
                        scan.stopped = true;
                        return null;
                    },
                }
            }
            return null;
        }

        pub fn snapshot(scan: *const ScanRange) u64 {
            return scan.snapshot_value;
        }

        pub fn finished(scan: *const ScanRange) bool {
            return scan.stopped or
                (scan.direction == .ascending and scan.cursor == scan.tree.values.items.len) or
                (scan.direction == .descending and scan.cursor == 0);
        }
    };
}

pub fn MemoryScanTreeType(
    comptime Context: type,
    comptime Tree: type,
    comptime Storage: type,
) type {
    _ = Storage;
    const Object = Tree.Table.Value;
    return struct {
        const ScanTree = @This();
        tree: *Tree,
        snapshot: u64,
        timestamp_min: u64,
        timestamp_max: u64,
        direction: Direction,
        cursor: ?u64 = null,
        state: enum { idle, reading, finished } = .idle,
        // Match the state machine's 16-byte alignment (see `MemoryForest`): the change-events
        // lookup recovers its parent from this via `@fieldParentPtr`.
        _alignment: [0]u128 = .{},

        pub fn init(
            tree: *Tree,
            _: *const ScanBuffer,
            snapshot: u64,
            timestamp_min: u64,
            timestamp_max: u64,
            direction: Direction,
        ) ScanTree {
            return .{
                .tree = tree,
                .snapshot = snapshot,
                .timestamp_min = timestamp_min,
                .timestamp_max = timestamp_max,
                .direction = direction,
            };
        }

        pub fn read(
            scan: *ScanTree,
            context: Context,
            callback: *const fn (Context, *ScanTree) void,
        ) void {
            scan.state = .reading;
            callback(context, scan);
            if (scan.state == .reading) scan.state = .idle;
        }

        pub fn next(scan: *ScanTree) error{ReadAgain}!?Object {
            var best_timestamp: ?u64 = null;
            var iterator = scan.tree.map.keyIterator();
            while (iterator.next()) |timestamp| {
                if (timestamp.* < scan.timestamp_min or timestamp.* > scan.timestamp_max) continue;
                if (scan.cursor) |cursor| {
                    if (scan.direction == .ascending and timestamp.* <= cursor) continue;
                    if (scan.direction == .descending and timestamp.* >= cursor) continue;
                }
                if (best_timestamp == null or
                    (scan.direction == .ascending and timestamp.* < best_timestamp.?) or
                    (scan.direction == .descending and timestamp.* > best_timestamp.?))
                {
                    best_timestamp = timestamp.*;
                }
            }
            const timestamp = best_timestamp orelse {
                scan.state = .finished;
                return null;
            };
            scan.cursor = timestamp;
            return scan.tree.map.get(timestamp).?;
        }
    };
}

const MemoryScanBufferPool = struct {
    scan_buffer: ScanBuffer = undefined,
    scan_buffer_used: u8 = 0,

    pub fn acquire_assume_capacity(pool: *MemoryScanBufferPool) *const ScanBuffer {
        // Mirror the real pool's bound. The mock ignores the buffer contents (scans read the
        // in-memory index directly), but the state machine relies on the acquire/reset
        // accounting, and over-acquiring past `lsm_scans_max` is a real bug worth catching.
        assert(pool.scan_buffer_used < constants.lsm_scans_max);
        pool.scan_buffer_used += 1;
        return &pool.scan_buffer;
    }

    pub fn reset(pool: *MemoryScanBufferPool) void {
        pool.scan_buffer_used = 0;
    }
};

pub fn MemoryForestType(comptime Storage: type, comptime groove_config: anytype) type {
    const config_fields = std.meta.fields(@TypeOf(groove_config));
    comptime var groove_fields: [config_fields.len]std.builtin.Type.StructField = undefined;
    comptime var option_fields: [config_fields.len]std.builtin.Type.StructField = undefined;
    for (config_fields, 0..) |field, i| {
        const Groove = @field(groove_config, field.name);
        groove_fields[i] = .{
            .name = field.name,
            .type = Groove,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Groove),
        };
        option_fields[i] = .{
            .name = field.name,
            .type = Groove.Options,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Groove.Options),
        };
    }
    const GroovesImpl = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &groove_fields,
        .decls = &.{},
        .is_tuple = false,
    } });
    const GroovesOptionsImpl = @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &option_fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    return struct {
        const Forest = @This();
        pub const Grooves = GroovesImpl;
        pub const GroovesOptions = GroovesOptionsImpl;

        grid: *Backend.GridType(Storage),
        grooves: GroovesImpl,
        scan_buffer_pool: MemoryScanBufferPool = .{},
        // The state machine recovers `*StateMachine` from `&self.forest` via `@fieldParentPtr`,
        // which requires the forest's alignment to match the state machine's (16). The real forest
        // reaches that alignment through its block buffers; this zero-size field does it here.
        _alignment: [0]u128 = .{},

        pub fn init(
            forest: *Forest,
            allocator: std.mem.Allocator,
            grid: *Backend.GridType(Storage),
            _: anytype,
            _: GroovesOptionsImpl,
        ) !void {
            forest.* = .{ .grid = grid, .grooves = undefined };
            var initialized: usize = 0;
            errdefer inline for (std.meta.fields(GroovesImpl), 0..) |field, i| {
                if (initialized > i) @field(forest.grooves, field.name).deinit();
            };
            inline for (std.meta.fields(GroovesImpl)) |field| {
                try @field(forest.grooves, field.name).init(allocator);
                initialized += 1;
            }
        }

        pub fn deinit(forest: *Forest, _: std.mem.Allocator) void {
            inline for (std.meta.fields(GroovesImpl)) |field| {
                @field(forest.grooves, field.name).deinit();
            }
        }

        pub fn reset(forest: *Forest) void {
            inline for (std.meta.fields(GroovesImpl)) |field| {
                @field(forest.grooves, field.name).reset();
            }
            forest.scan_buffer_pool.reset();
        }

        pub fn open(forest: *Forest, callback: *const fn (*Forest) void) void {
            callback(forest);
        }

        pub fn compact(forest: *Forest, callback: *const fn (*Forest) void, _: u64) void {
            callback(forest);
        }

        pub fn checkpoint(forest: *Forest, callback: *const fn (*Forest) void) void {
            callback(forest);
        }
    };
}
