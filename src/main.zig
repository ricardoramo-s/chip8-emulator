const std = @import("std");
const config = @import("config.zig");
const chip8 = @import("chip8.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

var timer: ?std.time.Timer = null;
fn nanotime() u64 {
    if (timer == null) {
        timer = std.time.Timer.start() catch unreachable;
    }
    return timer.?.read();
}

var screen: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <input_string>\n", .{args[0]});
        return;
    }

    const file_path = args[1];
    const file = std.fs.cwd().openFile(file_path, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Error opening file '{s}': {any}\n", .{ file_path, err });
        return err;
    };

    try chip8.Chip8.init(allocator, nanotime());
    try chip8.Chip8.loadROM(file);

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) {
        c.SDL_Log("Unable to initialize SDL: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    }
    defer c.SDL_Quit();

    screen = c.SDL_CreateWindow("Chip-8 Emulator", c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, chip8.WIDTH * config.MULT, chip8.HEIGHT * config.MULT, c.SDL_WINDOW_OPENGL) orelse
        {
        c.SDL_Log("Unable to create window: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyWindow(screen);

    renderer = c.SDL_CreateRenderer(screen, -1, 0) orelse {
        c.SDL_Log("Unable to create renderer: %s", c.SDL_GetError());
        return error.SDLInitializationFailed;
    };
    defer c.SDL_DestroyRenderer(renderer);

    _ = c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND);

    var last_cycle = nanotime();
    var quit = false;

    while (!quit) {
        const current_time = nanotime();
        const cycle_interval_ns: u64 = @intFromFloat((1.0 / config.CPU_FREQ) * std.time.ns_per_s);
        if (current_time - last_cycle < cycle_interval_ns) {
            continue;
        }

        defer last_cycle = nanotime();

        // event polling
        var event: c.SDL_Event = undefined;

        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => {
                    quit = true;
                },
                c.SDL_KEYUP, c.SDL_KEYDOWN => chip8.Chip8.handleKey(event),
                else => {},
            }
        }

        chip8.Chip8.updateTimers(current_time);
        chip8.Chip8.updateKeyboard();
        defer chip8.Chip8.resetKeyboardCache();

        chip8.Chip8.execute();
        chip8.Chip8.draw(renderer);
    }
}
