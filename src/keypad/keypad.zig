//! Keypad — maps host inputs to GBA KEYINPUT bits.
//!
//! KEYINPUT (0x04000130) is *active-low*: a bit reads 0 when the button is
//! held, 1 when released. Power-on default is 0x3FF.
//!
//! Bit layout: A=0 B=1 Select=2 Start=3 Right=4 Left=5 Up=6 Down=7 R=8 L=9.

pub const Button = enum(u4) {
    a = 0,
    b = 1,
    select = 2,
    start = 3,
    right = 4,
    left = 5,
    up = 6,
    down = 7,
    r = 8,
    l = 9,
};

pub const Keypad = struct {
    /// Active-low KEYINPUT value. Updated by frontend each frame.
    keyinput: u16 = 0x3FF,

    pub fn press(self: *Keypad, b: Button) void {
        self.keyinput &= ~(@as(u16, 1) << @intFromEnum(b));
    }

    pub fn release(self: *Keypad, b: Button) void {
        self.keyinput |= @as(u16, 1) << @intFromEnum(b);
    }
};
