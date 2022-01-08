const builtin = @import("builtin");
const STORAGE_VERSION = @import("config.zig").STORAGE_VERSION;
const PAGE_SIZE = @import("config.zig").PAGE_SIZE;
const std = @import("std");
const fs = std.fs;
const os = std.os;
const fcntl = @cImport({
    @cInclude("fcntl.h");
});

pub const SeekError = error{
    Unseekable,
    Unexpected,
};

pub const ExtendError = error{
    TooBig,
    Busy,
    Unexpected,
    AccessDenied,
};

pub const SizeError = error{
    AccessDenied,
    Unexpected,
};

const C = SeekError || ExtendError;

pub const ReadError = C || error{
    AccessDenied,
    Interrupted,
    NotOpenForReading,
    Unexpected,
};

pub const WriteError = C || error{
    NoSpaceLeft,
    AccessDenied,
    Unexpected,
    NotOpenForWriting,
};

// FILE HEADER
// - u16 block size
// - u16 number of pages
// - number of pages bytes for the occupancy map
pub const Header = struct {
    version: u16 = STORAGE_VERSION,
    pageSize: u16 = PAGE_SIZE,
};

pub const DiskError = WriteError || ReadError || error{
    InvalidPageSize,
};

pub const Manager = struct {
    readFn: fn (*Manager, []u8) ReadError!usize,
    writeFn: fn (*Manager, []const u8) WriteError!usize,
    seekFn: fn (*Manager, usize) SeekError!void,
    extendFn: fn (*Manager, usize) ExtendError!void,
    sizeFn: fn (*Manager) SizeError!usize,

    const Self = @This();
    pub fn init(self: *Self) DiskError!void {
        const size = try self.sizeFn(self);
        var hdr = Header{};
        if (size == 0) {
            // New file, write our initial header
            const buffer = std.mem.asBytes(&hdr);
            var index: usize = 0;
            while (index != buffer.len) {
                const amt = try self.writeFn(self, buffer[index..]);
                if (amt == 0) break;
                index += amt;
            }
        } else {
            // read existing header
            try self.seekFn(self, 0);
            _ = try self.readFn(self, std.mem.asBytes(&hdr));
            if (hdr.pageSize != PAGE_SIZE) {
                std.debug.print("Expected page size {}, found {}", .{ PAGE_SIZE, hdr.pageSize });
                return DiskError.InvalidPageSize;
            }
        }
    }

    fn seekTo(self: *Self, page: u64) C!void {
        const offset = @sizeOf(Header) + page * PAGE_SIZE;
        if (offset > try self.sizeFn(self)) {
            try self.extendFn(self, offset + PAGE_SIZE);
        }
        try self.seekFn(self, offset);
    }

    pub fn read(self: *Self, page: u64, buffer: []u8) ReadError!usize {
        try self.seekTo(self, page);
        return self.readFn(self, buffer);
    }

    pub fn readAll(self: *Self, page: u64, buffer: []u8) ReadError!usize {
        var index: usize = 0;
        try self.seekTo(page);
        while (index != buffer.len) {
            const amt = try self.readFn(self, buffer[index..]);
            if (amt == 0) return index;
            index += amt;
        }
        return index;
    }

    pub fn write(self: *Self, page: u64, buffer: []const u8) WriteError!usize {
        try self.seekTo(self, page);
        return self.writeFn(self, buffer);
    }

    pub fn writeAll(self: *Self, page: u64, buffer: []const u8) WriteError!void {
        try self.seekTo(page);
        var index: usize = 0;
        while (index != buffer.len) {
            const amt = try self.writeFn(self, buffer[index..]);
            if (amt == 0) break;
            index += amt;
        }
    }
};

fn initDirectIO(f: fs.File) !void {
    switch (builtin.os.tag) {
        .macos => {
            _ = try os.fcntl(f.handle, fcntl.F_NOCACHE, 0);
        },
        .linux => {
            _ = try os.fcntl(f.handle, fcntl.O_DIRECT, 0);
        },
        else => @compileError("os not supported"),
    }
}

pub const File = struct {
    f: fs.File,
    manager: Manager,

    const Self = @This();

    pub fn init(f: fs.File) !Self {
        try initDirectIO(f);
        var fm = Self{
            .f = f,
            .manager = .{
                .readFn = readImpl,
                .writeFn = writeImpl,
                .seekFn = seekImpl,
                .extendFn = extendImpl,
                .sizeFn = sizeImpl,
            },
        };
        try fm.manager.init();
        return fm;
    }

    const FReadError = fs.File.ReadError;
    fn readImpl(manager: *Manager, buffer: []u8) ReadError!usize {
        const self: fs.File = @fieldParentPtr(Self, "manager", manager).f;
        return self.read(buffer) catch |err| return switch (err) {
            FReadError.AccessDenied => ReadError.AccessDenied,
            FReadError.NotOpenForReading => ReadError.NotOpenForReading,
            else => ReadError.Unexpected,
        };
    }

    const FWriteError = fs.File.WriteError;
    fn writeImpl(manager: *Manager, buffer: []const u8) WriteError!usize {
        const self: fs.File = @fieldParentPtr(Self, "manager", manager).f;
        return self.write(buffer) catch |err| return switch (err) {
            FWriteError.AccessDenied => WriteError.AccessDenied,
            FWriteError.NotOpenForWriting => WriteError.NotOpenForWriting,
            FWriteError.NoSpaceLeft => WriteError.NoSpaceLeft,
            else => WriteError.Unexpected,
        };
    }

    const FSeekError = fs.File.SeekError;
    fn seekImpl(manager: *Manager, pos: usize) SeekError!void {
        const self: fs.File = @fieldParentPtr(Self, "manager", manager).f;
        return self.seekTo(pos) catch |err| return switch (err) {
            FSeekError.Unseekable => SeekError.Unseekable,
            else => SeekError.Unexpected,
        };
    }

    const FExtendError = fs.File.SetEndPosError;
    fn extendImpl(manager: *Manager, sz: usize) ExtendError!void {
        const self: fs.File = @fieldParentPtr(Self, "manager", manager).f;
        return self.setEndPos(sz) catch |err| return switch (err) {
            FExtendError.AccessDenied => ExtendError.AccessDenied,
            FExtendError.FileTooBig => ExtendError.TooBig,
            FExtendError.FileBusy => ExtendError.Busy,
            else => ExtendError.Unexpected,
        };
    }

    const FSizeError = fs.File.StatError;
    fn sizeImpl(manager: *Manager) SizeError!usize {
        const self: fs.File = @fieldParentPtr(Self, "manager", manager).f;
        const st = self.stat() catch |err| return switch (err) {
            FSizeError.AccessDenied => SizeError.AccessDenied,
            else => SizeError.Unexpected,
        };
        return st.size;
    }
};
