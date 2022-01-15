const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const math = std.math;
const Page = @import("page.zig").Page;
const Latch = @import("libdb").sync.Latch;
const XXHash = @import("libdb").XXHash;
const PAGE_SIZE = @import("config.zig").PAGE_SIZE;
const BufferManager = @import("buffer.zig").Manager;
const PageDirectory = @import("page_directory.zig").Directory;

pub const DirectoryPage = struct {
    pageID: u32,
    /// Log sequence number
    lsn: u32,
    globalDepth: u32,
    localDepths: [512]u8,
    bucketPageIDs: [512]u32,

    const Self = @This();

    pub fn init(page: *Page) *Self {
        var self = @ptrCast(*Self, @alignCast(@alignOf(Self), page.buffer));
        if (self.pageID != page.id) {
            self.lsn = 0;
            self.globalDepth = 0;
            for (self.localDepths) |*b| b.* = 1;
            for (self.bucketPageIDs) |*b| b.* = 0;
            self.pageID = page.id;
        }
        return self;
    }
};

/// The amount of data a BucketPage can store is based on the key, value,
/// and page sizes.
pub fn BucketPage(comptime K: type, comptime V: type) type {
    const Entry = struct { key: K, val: V };
    return struct {
        pub const maxEntries = 4 * PAGE_SIZE / (4 * @sizeOf(Entry) + 1);

        pageID: u64,
        occupied: [maxEntries]u1,
        // 0 if tombstoned or unoccupied
        // 1 otherwise
        readable: [maxEntries]u1,
        data: [maxEntries]Entry,
        const Self = @This();

        pub fn init(page: *Page) *Self {
            var self = @ptrCast(*Self, @alignCast(@alignOf(Self), page.buffer));
            if (self.pageID != page.id) {
                for (self.occupied) |*b| b.* = 0;
                for (self.readable) |*b| b.* = 0;
                self.pageID = page.id;
            }
            return self;
        }

        pub fn get(self: *Self, i: u16) ?Entry {
            if (self.readable[i] == 0) {
                return null;
            }
            return self.data[i];
        }

        pub fn insert(self: *Self, key: K, val: V, initIdx: u16) bool {
            if (self.put(initIdx, key, val)) {
                return true;
            }
            // Wrap around until we find a space
            var i = initIdx + 1;
            while (i != initIdx) : (i += 1) {
                if (i > Self.maxEntries) {
                    i = 0;
                }
                if (self.put(i, key, val)) {
                    return true;
                }
            }
            return false;
        }

        pub fn put(self: *Self, i: u16, key: K, val: V) bool {
            if (self.readable[i] == 1) {
                return false;
            }
            self.occupied[i] = 1;
            self.readable[i] = 1;
            self.data[i] = .{ .key = key, .val = val };
            return true;
        }

        pub fn remove(self: *Self, i: u16, key: K, val: V) void {
            if (self.data[i].key == key and self.data[i].val == val) {
                self.readable[i] = 0;
            }
        }

        pub fn forceRemove(self: *Self, i: u16) void {
            self.readable[i] = 0;
        }
    };
}

pub fn HashTable(comptime K: type, comptime V: type) type {
    const Bucket = BucketPage(K, V);
    const ArrayList = std.ArrayList(V);
    return struct {
        seed: u32,
        dirPage: *Page,
        directory: *DirectoryPage,
        bm: *BufferManager,
        pageDir: PageDirectory,
        latch: *Latch,
        mem: std.mem.Allocator,

        const Self = @This();

        pub fn new(alloc: std.mem.Allocator, bm: *BufferManager, pageDir: PageDirectory) !Self {
            var ht = try Self.init(alloc, bm, pageDir, try pageDir.allocate());
            errdefer ht.destroy() catch |e| {
                std.debug.panic("failed to destroy hashtable: {?}", .{e});
            };

            const dir = ht.directory;
            var dirhold = ht.dirPage.latch.exclusive();
            defer dirhold.release();

            var b1 = try pageDir.allocLatched(.exclusive);
            defer b1.deinit();
            _ = Bucket.init(b1.page);

            var b2 = try pageDir.allocLatched(.exclusive);
            defer b2.deinit();
            _ = Bucket.init(b2.page);

            dir.globalDepth = 1;
            // set up our first two buckets
            dir.localDepths[0] = 1;
            dir.localDepths[1] = 1;
            dir.bucketPageIDs[0] = b1.page.id;
            dir.bucketPageIDs[1] = b2.page.id;

            b1.page.dirty = true;
            b2.page.dirty = true;
            ht.dirPage.dirty = true;
            return ht;
        }

        pub fn init(alloc: std.mem.Allocator, bm: *BufferManager, pageDir: PageDirectory, dirPage: *Page) !Self {
            return Self{
                .seed = 0,
                .dirPage = dirPage,
                .directory = DirectoryPage.init(dirPage),
                .bm = bm,
                .pageDir = pageDir,
                .latch = try Latch.init(alloc),
                .mem = alloc,
            };
        }

        /// Destroy this hashtable. Do not call alongside deinit
        pub fn destroy(self: *Self) !void {
            var h = self.latch.exclusive();
            errdefer h.release();
            const pages = @as(u32, 2) << @intCast(u5, self.directory.globalDepth - 1);
            var idx: u16 = 0;
            while (idx < pages) : (idx += 1) {
                if (self.directory.bucketPageIDs[idx] == 0) {
                    // this should not occur
                    break;
                }
                try self.pageDir.free(self.directory.bucketPageIDs[idx]);
            }
            try self.pageDir.free(self.dirPage.id);
            self.dirPage.unpin();
            self.dirPage = undefined;
            self.directory = undefined;
            self.pageDir = undefined;
            h.release();
            self.mem.destroy(self.latch);
        }

        pub fn deinit(self: *Self) void {
            var h = self.latch.exclusive();
            self.dirPage.unpin();
            self.dirPage = undefined;
            self.directory = undefined;
            h.release();
            self.mem.destroy(self.latch);
        }

        inline fn checksum(self: Self, key: K) u64 {
            return XXHash.checksum(mem.asBytes(&key), self.seed);
        }

        inline fn prefix(self: Self, hsh: u64) u64 {
            const mask = ~@as(u64, 0) >> @intCast(u6, @bitSizeOf(u64) - self.directory.globalDepth);
            return hsh & mask;
        }

        inline fn localIndex(self: Self, hsh: u64) u16 {
            // idc if we're truncating here
            return @intCast(u16, 0xFFFF & (hsh >> @intCast(u6, self.directory.globalDepth))) % Bucket.maxEntries;
        }

        pub fn get(self: Self, key: K, results: *ArrayList) !void {
            const hsh = self.checksum(key);
            const pfx = self.prefix(hsh);
            var hold = self.latch.shared();
            defer hold.release();

            const bp = try self.bm.pin(self.directory.bucketPageIDs[pfx]);
            defer bp.unpin();
            var bh = bp.latch.shared();
            defer bh.release();

            var b = Bucket.init(bp);
            var localIdx = self.localIndex(hsh);
            if (b.get(@intCast(u16, localIdx))) |entry| {
                try results.append(entry.val);
            }

            var i = localIdx + 1;
            while (i != localIdx and b.occupied[i] == 1) : (i += 1) {
                if (i > Bucket.maxEntries) {
                    i = 0;
                }
                if (b.get(@intCast(u16, i))) |entry| {
                    try results.append(entry.val);
                }
            }
        }

        pub fn put(self: Self, key: K, val: V) anyerror!bool {
            const hsh = self.checksum(key);
            var idx = self.prefix(hsh);

            var hold = self.latch.exclusive();
            defer hold.release();

            const d = self.directory;
            const bp = try self.bm.pin(d.bucketPageIDs[idx]);
            defer bp.unpin();
            var bh = bp.latch.exclusive();
            defer bh.release();

            var b = Bucket.init(bp);
            var localIdx: u16 = self.localIndex(hsh);
            if (b.insert(key, val, localIdx)) {
                return true;
            }

            var mirror = try self.pageDir.allocLatched(.exclusive);
            defer mirror.deinit();
            var mb = Bucket.init(mirror.page);

            // Replace self.
            var replacement = try self.pageDir.allocLatched(.exclusive);
            defer replacement.deinit();
            var rb = Bucket.init(replacement.page);

            d.localDepths[idx] += 1;
            const newIdx = idx << 1;
            const mirrorIdx = idx + 1;
            if (d.localDepths[idx] > d.globalDepth) {
                // Double in size
                // Starting from the last active page, each gets
                // (idx << 1) and (idx << 1 + 1)
                // We then overwrite mirrorIdx with mirror's pageId
                var last = (@as(u32, 2) << @intCast(u5, d.globalDepth)) - 1;
                // The bucket at idx 0 never changes
                while (last > 0) : (last -= 1) {
                    d.bucketPageIDs[last << 1] = d.bucketPageIDs[last];
                    d.localDepths[last << 1] = d.localDepths[last];
                    d.bucketPageIDs[last << 1 + 1] = d.bucketPageIDs[last];
                    d.localDepths[last << 1 + 1] = d.localDepths[last];
                }
                d.bucketPageIDs[mirrorIdx] = mirror.page.id;
                d.bucketPageIDs[newIdx] = replacement.page.id;
                d.globalDepth += 1;
                // Recalculate insertion idx
                idx = self.prefix(hsh);
            } else {
                // Each of page, mirror should occupy 2**(global depth - old local dopth - 1) spaces
                const toOccupy = @as(u32, 2) << @intCast(u5, d.globalDepth - d.localDepths[idx] - 2);
                var taken: u32 = 0;
                while (taken < toOccupy) : (taken += 1) {
                    d.localDepths[newIdx + taken] = d.localDepths[idx];
                    d.bucketPageIDs[newIdx + taken] = replacement.page.id;
                }
                taken = 0;
                while (taken < toOccupy) : (taken += 1) {
                    d.localDepths[mirrorIdx + taken] = d.localDepths[idx];
                    d.bucketPageIDs[mirrorIdx + taken] = mirror.page.id;
                }
            }

            var i: u16 = 0;
            while (i < Bucket.maxEntries) : (i += 1) {
                if (b.readable[i] == 1) {
                    const e = b.data[i];
                    const ehsh = self.checksum(e.key);
                    if (self.prefix(ehsh) == mirrorIdx) {
                        assert(mb.insert(e.key, e.val, self.localIndex(ehsh)));
                    } else {
                        assert(rb.put(e.key, e.val, self.localIndex(ehsh)));
                    }
                }
            }

            // We're splitting so are replacing this page
            try self.pageDir.free(bp.id);

            if (idx == mirrorIdx) {
                return mb.insert(key, val, self.localIndex(hsh));
            } else {
                return try self.put(key, val);
            }
        }

        /// FIXME: merge pages if their load is below a certain amount
        pub fn remove(self: Self, key: K, val: V) anyerror!void {
            const hsh = self.checksum(key);
            const pfx = self.prefix(hsh);
            var hold = self.latch.shared();
            defer hold.release();

            var base = try self.bm.pinLatched(self.directory.bucketPageIDs[pfx], .exclusive);
            defer base.deinit();

            var b = Bucket.init(base.page);
            var localIdx: u16 = self.localIndex(hsh);
            // Not inserted
            if (b.occupied[localIdx] == 0) {
                return;
            }
            b.remove(localIdx, key, val);
            // Wrap around until we find a space
            var i = localIdx + 1;
            while (i != localIdx and b.occupied[i] == 1) : (i += 1) {
                if (i > Bucket.maxEntries) {
                    i = 0;
                }
                b.remove(i, key, val);
            }
        }
    };
}
