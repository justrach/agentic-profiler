const std = @import("std");
const output = @import("output.zig");
const symbolize = @import("symbolize.zig");

pub const StackFrame = symbolize.SymbolizedFrame;

pub const RegisterValue = struct {
    name: []const u8,
    value: []const u8,
    meaning: []const u8,
};

pub const CrashReport = struct {
    binary: []const u8,
    args: []const []const u8,
    backend: []const u8,
    termination: []const u8,
    exit_code: ?u32,
    signal_number: ?u32,
    signal_name: []const u8,
    fault_address: []const u8,
    summary: []const u8,
    probable_cause: []const u8,
    notes: []const u8,
    stdout: []const u8,
    stderr: []const u8,
    stack: []const StackFrame,
    registers: []const RegisterValue,

    pub fn render(self: CrashReport, writer: anytype, format: output.Format) !void {
        switch (format) {
            .text => try self.renderText(writer),
            .json => try self.writeJson(writer),
        }
    }

    pub fn writeJson(self: CrashReport, writer: anytype) !void {
        try self.renderJson(writer);
    }

    fn renderText(self: CrashReport, writer: anytype) !void {
        try writer.print("Crash report for {s}\n", .{self.binary});
        try writer.print("backend: {s}\n", .{self.backend});
        try writer.print("termination: {s}\n", .{self.termination});
        if (self.exit_code) |exit_code| {
            try writer.print("exit code: {d}\n", .{exit_code});
        }
        if (self.signal_number) |signal_number| {
            try writer.print("signal number: {d}\n", .{signal_number});
        }
        try writer.print("signal: {s}\n", .{self.signal_name});
        try writer.print("fault address: {s}\n", .{self.fault_address});
        if (self.args.len != 0) {
            try writer.writeAll("target args: ");
            for (self.args, 0..) |arg, index| {
                if (index != 0) try writer.writeAll(" ");
                try writer.writeAll(arg);
            }
            try writer.writeByte('\n');
        }
        try writer.print("summary: {s}\n", .{self.summary});
        try writer.print("probable cause: {s}\n", .{self.probable_cause});
        try writer.print("notes: {s}\n", .{self.notes});

        if (self.stdout.len != 0) {
            try writer.writeAll("\nCaptured stdout\n");
            try writer.writeAll(self.stdout);
            if (self.stdout[self.stdout.len - 1] != '\n') try writer.writeByte('\n');
        }

        if (self.stderr.len != 0) {
            try writer.writeAll("\nCaptured stderr\n");
            try writer.writeAll(self.stderr);
            if (self.stderr[self.stderr.len - 1] != '\n') try writer.writeByte('\n');
        }

        if (self.stack.len != 0) {
            try writer.writeAll("\nStack\n");
            for (self.stack) |frame| {
                if (frame.address) |address| {
                    try writer.print(
                        "  [{s}] {s}:{d}  {s}  @0x{x}  ({s})\n",
                        .{ frame.module, frame.file, frame.line, frame.symbol, address, frame.source },
                    );
                } else {
                    try writer.print(
                        "  [{s}] {s}:{d}  {s}  ({s})\n",
                        .{ frame.module, frame.file, frame.line, frame.symbol, frame.source },
                    );
                }
            }
        }

        if (self.registers.len != 0) {
            try writer.writeAll("\nRegisters\n");
            for (self.registers) |register| {
                try writer.print("  {s} = {s}  {s}\n", .{ register.name, register.value, register.meaning });
            }
        }
    }

    fn renderJson(self: CrashReport, writer: anytype) !void {
        try writer.writeAll("{\n");
        try writer.writeAll("  \"kind\": \"crash_report\",\n");
        try writer.writeAll("  \"binary\": ");
        try output.writeJsonString(writer, self.binary);
        try writer.writeAll(",\n  \"args\": ");
        try output.writeJsonStringArray(writer, self.args);
        try writer.writeAll(",\n  \"backend\": ");
        try output.writeJsonString(writer, self.backend);
        try writer.writeAll(",\n  \"termination\": ");
        try output.writeJsonString(writer, self.termination);
        try writer.writeAll(",\n  \"exit_code\": ");
        try writeOptionalU32(writer, self.exit_code);
        try writer.writeAll(",\n  \"signal_number\": ");
        try writeOptionalU32(writer, self.signal_number);
        try writer.writeAll(",\n  \"signal\": ");
        try output.writeJsonString(writer, self.signal_name);
        try writer.writeAll(",\n  \"fault_address\": ");
        try output.writeJsonString(writer, self.fault_address);
        try writer.writeAll(",\n  \"summary\": ");
        try output.writeJsonString(writer, self.summary);
        try writer.writeAll(",\n  \"probable_cause\": ");
        try output.writeJsonString(writer, self.probable_cause);
        try writer.writeAll(",\n  \"notes\": ");
        try output.writeJsonString(writer, self.notes);
        try writer.writeAll(",\n  \"stdout\": ");
        try output.writeJsonString(writer, self.stdout);
        try writer.writeAll(",\n  \"stderr\": ");
        try output.writeJsonString(writer, self.stderr);
        try writer.writeAll(",\n  \"stack\": [\n");
        for (self.stack, 0..) |frame, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"module\": ");
            try output.writeJsonString(writer, frame.module);
            try writer.writeAll(",\n      \"address\": ");
            try writeOptionalHexU64(writer, frame.address);
            try writer.writeAll(",\n");
            try writer.writeAll("      \"file\": ");
            try output.writeJsonString(writer, frame.file);
            try writer.print(",\n      \"line\": {d},\n", .{frame.line});
            try writer.writeAll("      \"symbol\": ");
            try output.writeJsonString(writer, frame.symbol);
            try writer.writeAll(",\n      \"source\": ");
            try output.writeJsonString(writer, frame.source);
            try writer.writeAll("\n    }");
        }
        try writer.writeAll("\n  ],\n  \"registers\": [\n");
        for (self.registers, 0..) |register, index| {
            if (index != 0) try writer.writeAll(",\n");
            try writer.writeAll("    {\n");
            try writer.writeAll("      \"name\": ");
            try output.writeJsonString(writer, register.name);
            try writer.writeAll(",\n      \"value\": ");
            try output.writeJsonString(writer, register.value);
            try writer.writeAll(",\n      \"meaning\": ");
            try output.writeJsonString(writer, register.meaning);
            try writer.writeAll("\n    }");
        }
        try writer.writeAll("\n  ]\n}\n");
    }
};

fn writeOptionalU32(writer: anytype, value: ?u32) !void {
    if (value) |number| {
        try writer.print("{d}", .{number});
    } else {
        try writer.writeAll("null");
    }
}

fn writeOptionalHexU64(writer: anytype, value: ?u64) !void {
    if (value) |number| {
        try writer.print("\"0x{x}\"", .{number});
    } else {
        try writer.writeAll("null");
    }
}
