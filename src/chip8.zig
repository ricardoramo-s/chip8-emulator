const std = @import("std");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub const WIDTH = 64;
pub const HEIGHT = 32;

const RAM_START = 0x200;
const RAM_END = 0xEA0;
const FONT_START = 0x50;
const FONT = [_]u8{
    0xF0, 0x90, 0x90, 0x90, 0xF0, // 0
    0x20, 0x60, 0x20, 0x20, 0x70, // 1
    0xF0, 0x10, 0xF0, 0x80, 0xF0, // 2
    0xF0, 0x10, 0xF0, 0x10, 0xF0, // 3
    0x90, 0x90, 0xF0, 0x10, 0x10, // 4
    0xF0, 0x80, 0xF0, 0x10, 0xF0, // 5
    0xF0, 0x80, 0xF0, 0x90, 0xF0, // 6
    0xF0, 0x10, 0x20, 0x40, 0x40, // 7
    0xF0, 0x90, 0xF0, 0x90, 0xF0, // 8
    0xF0, 0x90, 0xF0, 0x10, 0xF0, // 9
    0xF0, 0x90, 0xF0, 0x90, 0x90, // A
    0xE0, 0x90, 0xE0, 0x90, 0xE0, // B
    0xF0, 0x80, 0x80, 0x80, 0xF0, // C
    0xE0, 0x90, 0x90, 0x90, 0xE0, // D
    0xF0, 0x80, 0xF0, 0x80, 0xF0, // E
    0xF0, 0x80, 0xF0, 0x80, 0x80, // F
};

pub const Chip8 = struct {
    const Register = enum { V0, V1, V2, V3, V4, V5, V6, V7, V8, V9, VA, VB, VC, VD, VE, VF };

    var ram: [4096]u8 = std.mem.zeroes([4096]u8);
    var reg: [16]u8 = std.mem.zeroes([16]u8);
    var regI: u16 = 0;

    var pc: u16 = 0;

    var stack: [128]u16 = std.mem.zeroes([128]u16);
    var sp: u8 = 0;

    var screen_buf: [HEIGHT]u64 = std.mem.zeroes([HEIGHT]u64);
    var must_present: bool = false;

    var d_tmr: u8 = 0;
    var s_tmr: u8 = 0;

    var keyboard: u16 = 0;
    var released: u16 = 0;
    var pressed: u16 = 0;
    pub var key_map: std.AutoHashMap(i32, u4) = undefined;

    var random: std.Random = undefined;
    var last_timer_update: u64 = 0;

    pub fn loadROM(file: std.fs.File) !void {
        const file_size = try file.getEndPos();

        if (file_size > RAM_END - RAM_START) @panic("File exceeds the maximum size");

        _ = try file.readAll(ram[RAM_START..]);
    }

    pub fn init(allocator: std.mem.Allocator, current_time: u64) !void {
        var prng = std.rand.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });
        random = prng.random();

        @memcpy(ram[FONT_START .. FONT_START + FONT.len], FONT[0..]);

        key_map = std.AutoHashMap(i32, u4).init(allocator);

        try key_map.put(c.SDLK_1, 0x1);
        try key_map.put(c.SDLK_2, 0x2);
        try key_map.put(c.SDLK_3, 0x3);
        try key_map.put(c.SDLK_4, 0xC);

        try key_map.put(c.SDLK_q, 0x4);
        try key_map.put(c.SDLK_w, 0x5);
        try key_map.put(c.SDLK_e, 0x6);
        try key_map.put(c.SDLK_r, 0xD);

        try key_map.put(c.SDLK_a, 0x7);
        try key_map.put(c.SDLK_s, 0x8);
        try key_map.put(c.SDLK_d, 0x9);
        try key_map.put(c.SDLK_f, 0xE);

        try key_map.put(c.SDLK_z, 0xA);
        try key_map.put(c.SDLK_x, 0x0);
        try key_map.put(c.SDLK_c, 0xB);
        try key_map.put(c.SDLK_v, 0xF);

        last_timer_update = current_time;
        pc = RAM_START;
    }

    pub fn handleKey(event: c.SDL_Event) void {
        switch (event.type) {
            c.SDL_KEYUP => {
                const key = event.key.keysym.sym;
                if (!key_map.contains(key)) return;

                released ^= @as(u16, 1) << key_map.get(key).?;
            },
            c.SDL_KEYDOWN => {
                const key = event.key.keysym.sym;
                if (!key_map.contains(key)) return;

                pressed ^= @as(u16, 1) << key_map.get(key).?;
            },
            else => {},
        }
    }

    pub fn updateKeyboard() void {
        keyboard |= pressed;
        keyboard &= ~released;
    }

    pub fn resetKeyboardCache() void {
        pressed = 0;
        released = 0;
    }

    pub fn updateTimers(current_time: u64) void {
        const timer_interval_ns: u64 = @intFromFloat((1.0 / 60.0) * std.time.ns_per_s);
        if (current_time - last_timer_update >= timer_interval_ns) {
            d_tmr -= if (d_tmr > 0) 1 else 0;
            s_tmr -= if (s_tmr > 0) 1 else 0;

            last_timer_update = current_time;
        }
    }

    fn opcode_prefix(opcode: u16) u8 {
        return @truncate(opcode >> 12 & 0xF);
    }

    fn opcode_x(opcode: u16) u8 {
        return @truncate(opcode >> 8 & 0xF);
    }

    fn opcode_y(opcode: u16) u8 {
        return @truncate(opcode >> 4 & 0xF);
    }

    fn opcode_n(opcode: u16) u8 {
        return @truncate(opcode & 0xF);
    }

    fn opcode_nn(opcode: u16) u8 {
        return @truncate(opcode & 0xFF);
    }

    fn opcode_nnn(opcode: u16) u16 {
        return opcode & 0xFFF;
    }

    pub fn execute() void {
        const opcode = (@as(u16, ram[pc]) << 8) ^ ram[pc + 1];
        pc += 2;

        switch (opcode_prefix(opcode)) {
            0x0 => {
                switch (opcode_nn(opcode)) {
                    0xE0 => {
                        @memset(screen_buf[0..], 0);
                    },
                    0xEE => {
                        if (sp == 0) return;

                        sp -= 1;
                        pc = stack[sp];
                    },
                    else => {
                        @panic("Cannot call native machine code");
                    },
                }
            },
            0x1 => {
                // call NNN
                pc = opcode_nnn(opcode);
            },
            0x2 => {
                // 	*(0xNNN)()
                const addr = opcode_nnn(opcode);
                stack[sp] = pc;
                sp += 1;

                pc = addr;
            },
            0x3 => {
                // if (Vx == NN)
                if (reg[opcode_x(opcode)] == opcode_nn(opcode)) {
                    pc += 2;
                }
            },
            0x4 => {
                // if (Vx != NN)
                if (reg[opcode_x(opcode)] != opcode_nn(opcode)) {
                    pc += 2;
                }
            },
            0x5 => {
                if (opcode_n(opcode) == 0x0) {
                    // if (Vx == Vy)
                    if (reg[opcode_x(opcode)] == reg[opcode_y(opcode)]) {
                        pc += 2;
                    }
                } else {
                    @panic("Unhandled opcode");
                }
            },
            0x6 => {
                // Vx = NN
                reg[opcode_x(opcode)] = opcode_nn(opcode);
            },
            0x7 => {
                // Vx += NN
                reg[opcode_x(opcode)] +%= opcode_nn(opcode);
            },
            0x8 => {
                switch (opcode_n(opcode)) {
                    0x0 => {
                        // Vx = Vy
                        reg[opcode_x(opcode)] = reg[opcode_y(opcode)];
                    },
                    0x1 => {
                        // Vx |= Vy
                        reg[opcode_x(opcode)] |= reg[opcode_y(opcode)];
                        reg[@intFromEnum(Register.VF)] = 0;
                    },
                    0x2 => {
                        // Vx &= Vy
                        reg[opcode_x(opcode)] &= reg[opcode_y(opcode)];
                        reg[@intFromEnum(Register.VF)] = 0;
                    },
                    0x3 => {
                        // Vx ^= Vy
                        reg[opcode_x(opcode)] ^= reg[opcode_y(opcode)];
                        reg[@intFromEnum(Register.VF)] = 0;
                    },
                    0x4 => {
                        // Vx += Vy
                        const add = @addWithOverflow(reg[opcode_x(opcode)], reg[opcode_y(opcode)]);

                        reg[@intFromEnum(Register.VF)] = @as(u8, add[1]);
                        reg[opcode_x(opcode)] = @as(u8, add[0]);
                    },
                    0x5 => {
                        // Vx -= Vy
                        const sub = @subWithOverflow(reg[opcode_x(opcode)], reg[opcode_y(opcode)]);

                        reg[@intFromEnum(Register.VF)] = if (sub[1] == 1) 0 else 1;
                        reg[opcode_x(opcode)] = sub[0];
                    },
                    0x6 => {
                        // Vx >>= 1
                        const bit: u8 = reg[opcode_x(opcode)] & 0b1;

                        reg[@intFromEnum(Register.VF)] = bit;
                        reg[opcode_x(opcode)] = reg[opcode_y(opcode)];
                        reg[opcode_x(opcode)] >>= 1;
                    },
                    0x7 => {
                        // Vx = Vy - Vx
                        const sub = @subWithOverflow(reg[opcode_y(opcode)], reg[opcode_x(opcode)]);

                        reg[@intFromEnum(Register.VF)] = if (sub[1] == 1) 0 else 1;
                        reg[opcode_x(opcode)] = sub[0];
                    },
                    0xE => {
                        // Vx <<= 1
                        const bit: u8 = reg[opcode_x(opcode)] >> 7;

                        reg[@intFromEnum(Register.VF)] = bit;
                        reg[opcode_x(opcode)] = reg[opcode_y(opcode)];
                        reg[opcode_x(opcode)] <<= 1;
                    },
                    else => {
                        @panic("Unhandled opcode");
                    },
                }
            },
            0x9 => {
                if (opcode_n(opcode) == 0x0) {
                    // if (Vx != Vy)
                    if (reg[opcode_x(opcode)] != reg[opcode_y(opcode)]) {
                        pc += 2;
                    }
                } else {
                    @panic("Unhandled opcode");
                }
            },
            0xA => {
                // I = NNN
                regI = opcode_nnn(opcode);
            },
            0xB => {
                // PC = V0 + NNN
                pc = reg[@intFromEnum(Register.V0)] + opcode_nnn(opcode);
            },
            0xC => {
                // Vx = rand() & NN
                reg[opcode_x(opcode)] = random.int(u8) & opcode_nn(opcode);
            },
            0xD => {
                // draw(Vx, Vy, N)
                must_present = true;

                const rows = opcode_n(opcode);
                const x = reg[opcode_x(opcode)] % 64;
                const y = reg[opcode_y(opcode)] % 32;

                reg[@intFromEnum(Register.VF)] = 0;

                for (y..@min(rows + y, screen_buf.len)) |row| {
                    var sprite_row: u64 = undefined;

                    if (@bitSizeOf(u64) < x + 8) {
                        sprite_row = @as(u64, ram[regI + row - y]) >> @truncate(x + 8 - @bitSizeOf(u64));
                    } else {
                        sprite_row = @as(u64, ram[regI + row - y]) << @truncate(@bitSizeOf(u64) - x - 8);
                    }

                    if (sprite_row & screen_buf[row] != 0) {
                        reg[@intFromEnum(Register.VF)] = 1;
                    }

                    screen_buf[row] ^= sprite_row;
                }
            },
            0xE => {
                if (opcode & 0xFF == 0x9E) {
                    // if (key() == Vx)
                    if (keyboard & @as(u16, 1) << @as(u4, @truncate(reg[opcode_x(opcode)])) != 0) {
                        pc += 2;
                    }
                } else if (opcode & 0xFF == 0xA1) {
                    // if (key() != Vx)
                    if (keyboard & @as(u16, 1) << @as(u4, @truncate(reg[opcode_x(opcode)])) == 0) {
                        pc += 2;
                    }
                } else {
                    @panic("Unhandled opcode");
                }
            },
            0xF => {
                switch (opcode_nn(opcode)) {
                    0x07 => {
                        // Vx = get_delay()
                        reg[opcode_x(opcode)] = d_tmr;
                    },
                    0x0A => {
                        // Vx = get_key()
                        if (released != 0) {
                            for (0..17) |key| {
                                if ((@as(u16, 1) << @as(u4, @truncate(key))) & released != 0) {
                                    reg[opcode_x(opcode)] = @as(u4, @truncate(key));
                                    break;
                                }
                            }
                        } else {
                            pc -= 2;
                        }
                    },
                    0x15 => {
                        // delay_timer(Vx)
                        d_tmr = reg[opcode_x(opcode)];
                    },
                    0x18 => {
                        // sound_timer(Vx)
                        s_tmr = reg[opcode_x(opcode)];
                    },
                    0x1E => {
                        // I += Vx
                        regI += reg[opcode_x(opcode)];
                    },
                    0x29 => {
                        // I = sprite_addr[Vx]
                        regI = @as(u16, FONT_START + reg[opcode_x(opcode)] & 0xF) * 5;
                    },
                    0x33 => {
                        // FX33
                        const val = reg[opcode_x(opcode)];

                        ram[regI] = val / 100;
                        ram[regI + 1] = val / 10 % 10;
                        ram[regI + 2] = val % 10;
                    },
                    0x55 => {
                        // reg_dump(Vx, &I)
                        for (0..opcode_x(opcode) + 1) |offset| {
                            ram[regI + offset] = reg[offset];
                        }

                        regI += opcode_x(opcode) + 1;
                    },
                    0x65 => {
                        // reg_load(Vx, &I)
                        for (0..opcode_x(opcode) + 1) |offset| {
                            reg[offset] = ram[regI + offset];
                        }

                        regI += opcode_x(opcode) + 1;
                    },
                    else => {
                        @panic("Unhandled opcode");
                    },
                }
            },
            else => {
                @panic("Unhandled opcode");
            },
        }
    }

    pub fn draw(renderer: *c.SDL_Renderer) void {
        if (!must_present) {
            return;
        }

        must_present = false;

        _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);

        var rect: c.SDL_Rect = .{
            .x = 0,
            .y = 0,
            .w = config.MULT,
            .h = config.MULT,
        };

        for (screen_buf, 0..) |row, ri| {
            const row_size = @bitSizeOf(@TypeOf(row));
            var reverse_row = @bitReverse(row);
            for (0..row_size) |ci| {
                rect.x = @intCast(ci * config.MULT);
                rect.y = @intCast(ri * config.MULT);

                if (reverse_row & 0b1 == 1) {
                    _ = c.SDL_RenderFillRect(renderer, &rect);
                }

                reverse_row >>= 1;
            }
        }

        if (config.GRID) {
            _ = c.SDL_SetRenderDrawColor(renderer, 65, 65, 65, 128);

            for (0..64) |col| {
                _ = c.SDL_RenderDrawLine(renderer, @intCast(col * config.MULT), 0, @intCast(col * config.MULT), @intCast(screen_buf.len * config.MULT));
            }

            for (0..screen_buf.len) |row| {
                _ = c.SDL_RenderDrawLine(renderer, 0, @intCast(row * config.MULT), @intCast(64 * config.MULT), @intCast(row * config.MULT));
            }
        }

        c.SDL_RenderPresent(renderer);
    }
};
