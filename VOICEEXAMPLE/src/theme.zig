//! TalkBox theme (from the "TalkBox v2" design): an appliance-like
//! register — exactly one blue accent for live/primary things and
//! pastel tint pairs for the speaking card (info) and done chips
//! (success) — in two schemes. Light is the design's original: warm
//! gray grounds and white cards. Dark keeps the same register at
//! night: near-black grounds, cards one step lighter, the tint pairs
//! deepened so their inks brighten instead. High-contrast requests
//! fall back to the framework palettes in the SAME scheme
//! (accessibility beats brand).

const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const Color = canvas.Color;

/// First app-registered font slot (see `app_fonts` in main.zig).
pub const wordmark_font_id: canvas.FontId = canvas.min_registered_font_id;

pub const talkbox_colors = canvas.ColorTokens{
    .background = Color.rgb8(0xF5, 0xF5, 0xF7),
    .surface = Color.rgb8(0xFF, 0xFF, 0xFF),
    .surface_subtle = Color.rgb8(0xEF, 0xEF, 0xF2),
    .surface_pressed = Color.rgb8(0xE4, 0xE4, 0xE9),
    .text = Color.rgb8(0x1D, 0x1D, 0x1F),
    .text_muted = Color.rgb8(0x86, 0x86, 0x8B),
    .border = Color.rgb8(0xD8, 0xD8, 0xDD),
    .accent = Color.rgb8(0x0A, 0x7C, 0xFF),
    .accent_text = Color.rgb8(0xFF, 0xFF, 0xFF),
    .destructive = Color.rgb8(0xD0, 0x34, 0x2C),
    .destructive_text = Color.rgb8(0xFF, 0xFF, 0xFF),
    // The done-chip pastel pair (chips set background="success" +
    // foreground="success_text").
    .success = Color.rgb8(0xDD, 0xF0, 0xE3),
    .success_text = Color.rgb8(0x3F, 0x7D, 0x57),
    // The paused LED amber.
    .warning = Color.rgb8(0xE8, 0xB9, 0x0A),
    .warning_text = Color.rgb8(0x1D, 0x1D, 0x1F),
    // The speaking-card tint pair (card background="info" +
    // badge foreground="info_text") and the pillar tint.
    .info = Color.rgb8(0xE3, 0xEE, 0xFC),
    .info_text = Color.rgb8(0x2D, 0x6A, 0xC0),
    .focus_ring = Color.rgb8(0x0A, 0x7C, 0xFF),
    .shadow = Color.rgba8(0, 0, 0, 30),
    .disabled = Color.rgb8(0xE9, 0xE9, 0xED),
};

/// The same register flipped for dark: the light ground becomes the
/// ink (#F5F5F7), cards sit one step LIGHTER than the background
/// (elevation by lightness, per the framework's dark convention), the
/// accent brightens one notch so filled blue holds contrast on dark,
/// and each pastel pair inverts — deep tinted surfaces with the pair's
/// ink brightened (the ink also colors the playing LED, which must
/// still read across the room).
pub const talkbox_colors_dark = canvas.ColorTokens{
    .background = Color.rgb8(0x1C, 0x1C, 0x1E),
    .surface = Color.rgb8(0x2C, 0x2C, 0x2E),
    .surface_subtle = Color.rgb8(0x24, 0x24, 0x27),
    .surface_pressed = Color.rgb8(0x3A, 0x3A, 0x3E),
    .text = Color.rgb8(0xF5, 0xF5, 0xF7),
    .text_muted = Color.rgb8(0x98, 0x98, 0x9D),
    .border = Color.rgb8(0x3D, 0x3D, 0x42),
    .accent = Color.rgb8(0x0A, 0x84, 0xFF),
    .accent_text = Color.rgb8(0xFF, 0xFF, 0xFF),
    .destructive = Color.rgb8(0xFF, 0x45, 0x3A),
    .destructive_text = Color.rgb8(0xFF, 0xFF, 0xFF),
    // The done-chip pair, deepened: green tint surface, brighter ink.
    .success = Color.rgb8(0x22, 0x3B, 0x2D),
    .success_text = Color.rgb8(0x7B, 0xC8, 0x96),
    // The paused LED amber holds — it is a lit lens, same day or night.
    .warning = Color.rgb8(0xE8, 0xB9, 0x0A),
    .warning_text = Color.rgb8(0x1D, 0x1D, 0x1F),
    // The speaking-card pair, deepened the same way.
    .info = Color.rgb8(0x21, 0x38, 0x50),
    .info_text = Color.rgb8(0x7F, 0xB3, 0xF2),
    .focus_ring = Color.rgb8(0x0A, 0x84, 0xFF),
    .shadow = Color.rgba8(0, 0, 0, 120),
    .disabled = Color.rgb8(0x31, 0x31, 0x35),
};

pub fn tokens(color_scheme: canvas.ColorScheme, high_contrast: bool, reduce_motion: bool) canvas.DesignTokens {
    var out = canvas.DesignTokens.theme(.{
        .color_scheme = color_scheme,
        .contrast = if (high_contrast) .high else .standard,
        .reduce_motion = reduce_motion,
    });
    if (!high_contrast) {
        switch (color_scheme) {
            .light => {
                out.colors = talkbox_colors;
                // Primary controls are the design's filled blue; hover
                // and press DEEPEN it on light grounds.
                out.controls.button_primary = .{
                    .background = talkbox_colors.accent,
                    .hover_background = Color.rgb8(0x06, 0x69, 0xD6),
                    .active_background = Color.rgb8(0x06, 0x5C, 0xBC),
                    .foreground = talkbox_colors.accent_text,
                    .border = talkbox_colors.accent,
                };
            },
            .dark => {
                out.colors = talkbox_colors_dark;
                // Same filled blue, but hover and press LIGHTEN it — a
                // dark ground swallows a deepening hover.
                out.controls.button_primary = .{
                    .background = talkbox_colors_dark.accent,
                    .hover_background = Color.rgb8(0x2E, 0x93, 0xFF),
                    .active_background = Color.rgb8(0x4D, 0xA2, 0xFF),
                    .foreground = talkbox_colors_dark.accent_text,
                    .border = talkbox_colors_dark.accent,
                };
            },
        }
    }
    out.radius = .{ .sm = 8, .md = 10, .lg = 16, .xl = 22 };
    // The design's Pacifico script wordmark: registered as the app's
    // one custom face and reached through the mono slot — TalkBox has
    // no other mono text, so only the wordmark's <span mono> gets it.
    out.typography.mono_font_id = wordmark_font_id;
    return out;
}
