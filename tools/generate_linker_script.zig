const std = @import("std");
const microzig = @import("build-internals");
const MemoryRegion = microzig.MemoryRegion;
const GenerateOptions = microzig.LinkerScript.GenerateOptions;

pub const Args = struct {
    cpu_name: []const u8,
    cpu_arch: std.Target.Cpu.Arch,
    chip_name: []const u8,
    memory_regions: []const MemoryRegion,
    generate: GenerateOptions,
    ram_image: bool,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();

    var arena = std.heap.ArenaAllocator.init(debug_allocator.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();
    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3 or args.len > 4) {
        return error.UsageError;
    }

    const json_args = args[1];
    const output_path = args[2];

    const parsed_args = try std.json.parseFromSliceLeaky(Args, allocator, json_args, .{});

    const maybe_user_linker_script = if (args.len == 4)
        try std.fs.cwd().readFileAlloc(allocator, args[3], 100 * 1024 * 1024)
    else
        null;

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    const writer = file.writer();
    try writer.print(
        \\/*
        \\ * Target CPU:  {[cpu]s}
        \\ * Target Chip: {[chip]s}
        \\ */
        \\
        \\
    , .{
        .cpu = parsed_args.cpu_name,
        .chip = parsed_args.chip_name,
    });

    // name all unnamed regions
    const region_names: [][]const u8 = try allocator.alloc([]const u8, parsed_args.memory_regions.len);
    {
        var counters: [5]usize = @splat(0);
        for (region_names, parsed_args.memory_regions) |*region_name, region| {
            if (region.name) |name| {
                region_name.* = try allocator.dupe(u8, name);
            } else {
                region_name.* = try std.fmt.allocPrint(allocator, "{s}{}", .{
                    @tagName(region.tag),
                    counters[@intFromEnum(region.tag)],
                });
            }
            counters[@intFromEnum(region.tag)] += 1;
        }
    }

    if (parsed_args.generate != .none) {
        try writer.writeAll(
            \\/*
            \\ * This section was auto-generated by microzig.
            \\ */
            \\MEMORY
            \\{
            \\
        );

        for (region_names, parsed_args.memory_regions) |region_name, region| {
            // flash (rx!w) : ORIGIN = 0x00000000, LENGTH = 512k

            try writer.print("  {s} (", .{region_name});

            if (region.access.read) try writer.writeAll("r");
            if (region.access.write) try writer.writeAll("w");
            if (region.access.execute) try writer.writeAll("x");

            if (!region.access.read or !region.access.write or !region.access.execute) {
                try writer.writeAll("!");
                if (!region.access.read) try writer.writeAll("r");
                if (!region.access.write) try writer.writeAll("w");
                if (!region.access.execute) try writer.writeAll("x");
            }
            try writer.writeAll(")");

            try writer.print(" : ORIGIN = 0x{X:0>8}, LENGTH = 0x{X:0>8}\n", .{ region.offset, region.length });
        }

        try writer.writeAll("}\n");
    }

    if (parsed_args.generate == .memory_regions_and_sections) {
        const flash_region_name = for (region_names, parsed_args.memory_regions) |region_name, region| {
            if (region.tag == .flash) {
                break region_name;
            }
        } else return error.NoFlashRegion;

        const ram_region_name, const ram_region = for (region_names, parsed_args.memory_regions) |region_name, region| {
            if (region.tag == .ram) {
                break .{ region_name, region };
            }
        } else return error.NoRamRegion;

        if (parsed_args.ram_image and !ram_region.access.execute) {
            return error.RamRegionNotExecutableInRamImage;
        }

        const options = parsed_args.generate.memory_regions_and_sections;

        try writer.writeAll(
            \\SECTIONS
            \\{
            \\
        );

        if (!parsed_args.ram_image) {
            try writer.print(
                \\  .flash_start :
                \\  {{
                \\    KEEP(*(microzig_flash_start))
                \\  }} > {s}
                \\
            ,
                .{flash_region_name},
            );
        } else {
            try writer.print(
                \\  .ram_start :
                \\  {{
                \\    KEEP(*(microzig_ram_start))
                \\  }} > {s}
                \\
            ,
                .{ram_region_name},
            );
        }

        try writer.writeAll(
            \\
            \\  .text :
            \\  {
            \\    *(.text*)
            \\
        );

        if (parsed_args.ram_image) {
            try writer.writeAll(
                \\    *(.ram_text*)
                \\
            );
        }

        if (options.rodata_location == .flash and !parsed_args.ram_image) {
            try writer.writeAll(
                \\    *(.srodata*)
                \\    *(.rodata*)
                \\
            );
        }

        try writer.print(
            \\  }} > {s}
            \\
        , .{if (!parsed_args.ram_image) flash_region_name else ram_region_name});

        switch (parsed_args.cpu_arch) {
            .arm, .thumb => try writer.print(
                \\
                \\  .ARM.extab : {{
                \\    *(.ARM.extab* .gnu.linkonce.armextab.*)
                \\  }} > {[flash]s}
                \\
                \\  .ARM.exidx : {{
                \\    *(.ARM.exidx* .gnu.linkonce.armexidx.*)
                \\  }} > {[flash]s}
                \\
            , .{ .flash = if (!parsed_args.ram_image) flash_region_name else ram_region_name }),
            else => {},
        }

        try writer.writeAll(
            \\
            \\  .data :
            \\  {
            \\    microzig_data_start = .;
            \\    *(.sdata*)
            \\    *(.data*)
            \\
        );

        if (options.rodata_location == .ram or parsed_args.ram_image) {
            try writer.writeAll(
                \\    *(.srodata*)
                \\    *(.rodata*)
                \\
            );
        }

        if (ram_region.access.execute and !parsed_args.ram_image) {
            try writer.writeAll(
                // NOTE: should this be `microzig_ram_text`?
                \\    KEEP(*(.ram_text))
                \\
            );
        }

        try writer.print(
            \\    microzig_data_end = .;
            \\  }} > {s}
            \\
            \\  .bss {s}:
            \\  {{
            \\    microzig_bss_start = .;
            \\    *(.sbss*)
            \\    *(.bss*)
            \\    microzig_bss_end = .;
            \\  }} > {s}
            \\
        , .{
            if (!parsed_args.ram_image)
                try std.fmt.allocPrint(allocator, "{s} AT> {s}", .{ ram_region_name, flash_region_name })
            else
                ram_region_name,
            if (!parsed_args.ram_image) "(NOLOAD) " else "",
            ram_region_name,
        });

        if (!parsed_args.ram_image) {
            try writer.print(
                \\
                \\  .flash_end :
                \\  {{
                \\    microzig_flash_end = .;
                \\  }} > {s}
                \\
            , .{flash_region_name});
        }

        try writer.writeAll(
            \\
            \\  microzig_data_load_start = LOADADDR(.data);
            \\
        );
        switch (parsed_args.cpu_arch) {
            .riscv32, .riscv64 => try writer.writeAll(
                \\  PROVIDE(__global_pointer$ = microzig_data_start + 0x800);
                \\
            ),
            else => {},
        }

        try writer.writeAll("}\n");
    }

    if (parsed_args.generate != .none) {
        try writer.writeAll(
            \\/*
            \\ * End of auto-generated section.
            \\ */
            \\
        );
    }

    if (maybe_user_linker_script) |user_linker_script| {
        try writer.writeAll(user_linker_script);
    }
}
