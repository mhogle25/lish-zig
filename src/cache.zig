const std = @import("std");
const exec_mod = @import("exec.zig");

const Allocator = std.mem.Allocator;
const Expression = exec_mod.Expression;
const Unit = exec_mod.Unit;
const ResolvedSlot = exec_mod.ResolvedSlot;

/// Generic LRU cache mapping string keys to values of type V.
/// O(1) get, put, and eviction via HashMap + doubly-linked list.
pub fn LruCache(comptime V: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            key: []const u8 = "",
            value: V = undefined,
            prev: ?usize = null,
            next: ?usize = null,
            active: bool = false,
        };

        nodes: []Node,
        map: std.StringHashMapUnmanaged(usize),
        head: ?usize = null,
        tail: ?usize = null,
        len: usize = 0,
        capacity: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            std.debug.assert(capacity > 0);
            const nodes = try allocator.alloc(Node, capacity);
            @memset(nodes, Node{});
            return .{
                .nodes = nodes,
                .map = .{},
                .capacity = capacity,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.nodes) |node| {
                if (node.active) {
                    self.allocator.free(node.key);
                }
            }
            self.map.deinit(self.allocator);
            self.allocator.free(self.nodes);
        }

        /// Look up a cached value by key.
        /// On hit, moves the entry to the front (most recently used).
        pub fn get(self: *Self, key: []const u8) ?V {
            const index = self.map.get(key) orelse return null;
            self.moveToFront(index);
            return self.nodes[index].value;
        }

        /// Store a value in the cache. If the cache is full, evicts
        /// the least recently used entry.
        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            // Update existing entry
            if (self.map.get(key)) |index| {
                self.nodes[index].value = value;
                self.moveToFront(index);
                return;
            }

            // Get a slot: either a fresh one or evict the LRU tail
            const index = if (self.len < self.capacity) blk: {
                const idx = self.len;
                self.len += 1;
                break :blk idx;
            } else blk: {
                const tail_idx = self.tail.?;
                _ = self.map.remove(self.nodes[tail_idx].key);
                self.allocator.free(self.nodes[tail_idx].key);
                self.removeFromList(tail_idx);
                self.nodes[tail_idx].active = false;
                break :blk tail_idx;
            };

            const owned_key = try self.allocator.dupe(u8, key);
            self.nodes[index] = .{
                .key = owned_key,
                .value = value,
                .active = true,
            };
            try self.map.put(self.allocator, owned_key, index);
            self.addToFront(index);
        }

        /// Remove all entries from the cache.
        pub fn clear(self: *Self) void {
            for (self.nodes[0..self.len]) |*node| {
                if (node.active) {
                    self.allocator.free(node.key);
                    node.* = .{};
                }
            }
            self.map.clearRetainingCapacity();
            self.head = null;
            self.tail = null;
            self.len = 0;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }


        fn moveToFront(self: *Self, index: usize) void {
            if (self.head == index) return;
            self.removeFromList(index);
            self.addToFront(index);
        }

        fn addToFront(self: *Self, index: usize) void {
            self.nodes[index].prev = null;
            self.nodes[index].next = self.head;
            if (self.head) |old_head| {
                self.nodes[old_head].prev = index;
            }
            self.head = index;
            if (self.tail == null) {
                self.tail = index;
            }
        }

        fn removeFromList(self: *Self, index: usize) void {
            const node = self.nodes[index];
            if (node.prev) |prev| {
                self.nodes[prev].next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next) |next| {
                self.nodes[next].prev = node.prev;
            } else {
                self.tail = node.prev;
            }
        }
    };
}

/// LRU of lowered top-level units, keyed by source. A cached Unit points into the
/// parse allocator, which must outlive the cache (a session-scoped arena).
pub const ExpressionCache = LruCache(Unit);

/// Per-registry name resolution: a pin-aware LRU keyed by a unit's `unit_id`, each
/// entry owning that unit's `[]ResolvedSlot`. Per-unit keying makes site-id
/// aliasing impossible. Eviction frees the slot array, so an entry whose slots are
/// live on the stack is pinned (re-entrant count); eviction skips pinned entries,
/// and the new unit runs un-cached if all are pinned.
pub const ResolutionCache = struct {
    const Node = struct {
        unit_id: u32 = 0,
        slots: []ResolvedSlot = &.{},
        pins: u32 = 0,
        prev: ?usize = null,
        next: ?usize = null,
        active: bool = false,
    };

    nodes: []Node = &.{}, // allocated lazily on first use so init can't fail
    map: std.AutoHashMapUnmanaged(u32, usize) = .{},
    head: ?usize = null,
    tail: ?usize = null,
    len: usize = 0,
    capacity: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize) ResolutionCache {
        std.debug.assert(capacity > 0);
        return .{ .capacity = capacity, .allocator = allocator };
    }

    pub fn deinit(self: *ResolutionCache) void {
        for (self.nodes[0..self.len]) |node| {
            if (node.active) self.allocator.free(node.slots);
        }
        if (self.nodes.len > 0) self.allocator.free(self.nodes);
        self.map.deinit(self.allocator);
    }

    /// Enter a unit: pin it and return its slot array (a fresh `.unresolved` array
    /// on a miss), or null when every entry is pinned (caller runs un-cached). The
    /// slice stays valid until the matching `unpin`.
    pub fn enter(self: *ResolutionCache, unit_id: u32, site_count: u32) Allocator.Error!?[]ResolvedSlot {
        try self.ensureNodes();

        if (self.map.get(unit_id)) |index| {
            self.nodes[index].pins += 1;
            self.moveToFront(index);
            return self.nodes[index].slots;
        }

        try self.map.ensureUnusedCapacity(self.allocator, 1);
        const index = if (self.len < self.capacity) blk: {
            const idx = self.len;
            self.len += 1;
            break :blk idx;
        } else (self.evictVictim() orelse return null);

        const slots = try self.allocator.alloc(ResolvedSlot, site_count);
        @memset(slots, .unresolved);
        self.nodes[index] = .{ .unit_id = unit_id, .slots = slots, .pins = 1, .active = true };
        self.map.putAssumeCapacity(unit_id, index);
        self.addToFront(index);
        return slots;
    }

    /// Release one pin on a unit (balances a successful `enter`).
    pub fn unpin(self: *ResolutionCache, unit_id: u32) void {
        if (self.map.get(unit_id)) |index| self.nodes[index].pins -= 1;
    }

    /// Drop every memoized resolution (slot arrays freed). Valid only between
    /// evaluations, when nothing is pinned (the existing register-time invariant).
    pub fn clear(self: *ResolutionCache) void {
        for (self.nodes[0..self.len]) |*node| {
            if (node.active) {
                self.allocator.free(node.slots);
                node.* = .{};
            }
        }
        self.map.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.len = 0;
    }

    pub fn count(self: *const ResolutionCache) usize {
        return self.map.count();
    }

    fn ensureNodes(self: *ResolutionCache) Allocator.Error!void {
        if (self.nodes.len == 0) {
            self.nodes = try self.allocator.alloc(Node, self.capacity);
            @memset(self.nodes, Node{});
        }
    }

    // Reclaim the least-recently-used unpinned entry (freeing its slots), or null
    // if every entry is pinned. Only called when the table is at capacity.
    fn evictVictim(self: *ResolutionCache) ?usize {
        var maybe = self.tail;
        while (maybe) |index| : (maybe = self.nodes[index].prev) {
            if (self.nodes[index].pins == 0) {
                _ = self.map.remove(self.nodes[index].unit_id);
                self.allocator.free(self.nodes[index].slots);
                self.removeFromList(index);
                self.nodes[index].active = false;
                return index;
            }
        }
        return null;
    }

    fn moveToFront(self: *ResolutionCache, index: usize) void {
        if (self.head == index) return;
        self.removeFromList(index);
        self.addToFront(index);
    }

    fn addToFront(self: *ResolutionCache, index: usize) void {
        self.nodes[index].prev = null;
        self.nodes[index].next = self.head;
        if (self.head) |old_head| self.nodes[old_head].prev = index;
        self.head = index;
        if (self.tail == null) self.tail = index;
    }

    fn removeFromList(self: *ResolutionCache, index: usize) void {
        const node = self.nodes[index];
        if (node.prev) |prev| self.nodes[prev].next = node.next else self.head = node.next;
        if (node.next) |next| self.nodes[next].prev = node.prev else self.tail = node.prev;
    }
};


const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");

fn parseAndValidate(allocator: Allocator, source: []const u8) !Unit {
    const ast_root = try expr_parser.parse(allocator, source);
    const result = try validation_mod.validate(allocator, ast_root);
    return switch (result) {
        .ok => |unit| unit,
        .err => error.TestUnexpectedResult,
    };
}

test "cache: basic put and get" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    const expression = try parseAndValidate(alloc, "+ 1 2");
    try cache.put("+ 1 2", expression);

    const cached = cache.get("+ 1 2");
    try std.testing.expect(cached != null);
    try std.testing.expectEqualStrings("+", cached.?.root.name.body.value_literal.?.string);
}

test "cache: miss returns null" {
    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    try std.testing.expect(cache.get("nonexistent") == null);
}

test "cache: update existing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    const expr1 = try parseAndValidate(alloc, "+ 1 2");
    const expr2 = try parseAndValidate(alloc, "* 3 4");

    try cache.put("key", expr1);
    try cache.put("key", expr2);

    try std.testing.expectEqual(@as(usize, 1), cache.count());

    const cached = cache.get("key").?;
    try std.testing.expectEqualStrings("*", cached.root.name.body.value_literal.?.string);
}

test "cache: evicts least recently used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));

    // Cache is full (capacity 3). Inserting "d" should evict "a" (LRU).
    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") != null);
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: access refreshes LRU order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));

    // Access "a" to refresh it, now "b" is the LRU
    _ = cache.get("a");

    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: clear empties the cache" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));

    try std.testing.expectEqual(@as(usize, 2), cache.count());

    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") == null);
}

test "cache: refill after clear" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    try cache.put("a", try parseAndValidate(alloc, "+ 1 2"));
    try cache.put("b", try parseAndValidate(alloc, "+ 3 4"));
    cache.clear();

    try cache.put("c", try parseAndValidate(alloc, "+ 5 6"));
    try cache.put("d", try parseAndValidate(alloc, "+ 7 8"));

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("d") != null);
}

test "cache: repeated evictions cycle correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cache = try ExpressionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    const expression = try parseAndValidate(alloc, "+ 1 2");

    // Fill and evict several rounds
    try cache.put("a", expression);
    try cache.put("b", expression);
    try cache.put("c", expression); // evicts "a"
    try cache.put("d", expression); // evicts "b"
    try cache.put("e", expression); // evicts "c"

    try std.testing.expectEqual(@as(usize, 2), cache.count());
    try std.testing.expect(cache.get("a") == null);
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expect(cache.get("c") == null);
    try std.testing.expect(cache.get("d") != null);
    try std.testing.expect(cache.get("e") != null);
}

test "cache: generic with simple values" {
    var cache = try LruCache(i32).init(std.testing.allocator, 3);
    defer cache.deinit();

    try cache.put("one", 1);
    try cache.put("two", 2);
    try cache.put("three", 3);

    try std.testing.expectEqual(@as(i32, 1), cache.get("one").?);
    try std.testing.expectEqual(@as(i32, 2), cache.get("two").?);
    try std.testing.expectEqual(@as(i32, 3), cache.get("three").?);

    // Evict LRU ("one" was accessed most recently due to get above, "two" next, so
    // after the gets above the order is: three(head), two, one(tail)
    // Wait, gets move to front, so after get("one"), get("two"), get("three"):
    // order is three(head), two, one(tail)
    try cache.put("four", 4); // evicts "one" (tail)

    try std.testing.expect(cache.get("one") == null);
    try std.testing.expectEqual(@as(i32, 2), cache.get("two").?);
}

test "resolution cache: enter allocates unresolved slots, re-enter reuses them" {
    var cache = ResolutionCache.init(std.testing.allocator, 4);
    defer cache.deinit();

    const slots = (try cache.enter(1, 3)).?;
    try std.testing.expectEqual(@as(usize, 3), slots.len);
    try std.testing.expect(slots[0] == .unresolved);
    cache.unpin(1);

    // Same unit id returns the same (still-memoized) array.
    const again = (try cache.enter(1, 3)).?;
    try std.testing.expectEqual(slots.ptr, again.ptr);
    cache.unpin(1);
}

test "resolution cache: a pinned entry is never evicted" {
    var cache = ResolutionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    const s1 = (try cache.enter(1, 1)).?; // unit 1 stays pinned (no unpin)
    _ = (try cache.enter(2, 1)).?;
    cache.unpin(2);

    // Table full as {1 pinned, 2 unpinned}; entering 3 must evict 2, not 1.
    _ = (try cache.enter(3, 1)).?;
    cache.unpin(3);
    cache.unpin(1);

    // Unit 1 survived: re-entering returns its original slot array.
    const s1b = (try cache.enter(1, 1)).?;
    try std.testing.expectEqual(s1.ptr, s1b.ptr);
    cache.unpin(1);
}

test "resolution cache: runs un-cached when every entry is pinned" {
    var cache = ResolutionCache.init(std.testing.allocator, 2);
    defer cache.deinit();

    _ = (try cache.enter(1, 1)).?;
    _ = (try cache.enter(2, 1)).?;
    try std.testing.expect((try cache.enter(3, 1)) == null);

    cache.unpin(1);
    cache.unpin(2);
}
