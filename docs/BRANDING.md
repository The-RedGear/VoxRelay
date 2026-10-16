# VoxRelay branding asset checklist

These are production recommendations for VoxRelay, not hard limits unless noted.
Start with editable vector artwork; we can generate the small exports and Windows
icon from the masters. Do not build every size by hand.

## Essential artwork

| Asset | Master / export | Use |
|---|---|---|
| Standalone symbol | SVG master; transparent PNG at 1024 × 1024 | App identity, About, profile image, source for Windows icons |
| Horizontal logo: symbol + VoxRelay | SVG master; transparent PNG around 2000 × 500, preserving your actual proportions | Sidebar, About, README and website |
| Single-color symbol and logo | SVG in white and dark versions | Tiny tray icon, light/dark backgrounds, monochrome uses |
| Repository / launch card | 1280 × 640 PNG or JPG, solid background, **under 1 MB** | GitHub social preview and link sharing |

Provide the original editable design file too, if it is not SVG. Outline the
lettering in final SVG exports, and keep an editable-text source separately.
Export raster art in sRGB. Use real transparency, not a checkerboard background.

## Windows icon exports (we can generate these)

- `VoxRelay.ico`: one multi-resolution ICO containing 16, 20, 24, 32, 40, 48, 64,
  128 and 256 pixel square images. This replaces `assets/VoxRelay.ico` for the
  executable and window icon. Aim below 500 KB; this is a project target, not a
  Windows file-size limit.
- `VoxRelay-icon.png`: transparent square PNG, 256 × 256. This replaces the
  current tray source at `assets/VoxRelay-icon.png`.
- Simplified tray mark: SVG master, tested at **16 × 16 and 20 × 20**. Use a
  recognizable silhouette with no lettering or fine detail. It can differ slightly
  from the full-size symbol for legibility. Test against light and dark taskbars.

Do not bake rounded-square backgrounds into every export. Supply the bare
transparent symbol, plus a separate app-tile version if the background is part of
the branding. Leave consistent clear space and keep the main mark inside roughly
80–85% of the square.

## Current visual system

- Accent: `#B6A3FF` (lavender)
- Deep background: `#15131D`
- Raised surfaces: `#1E1A27`
- Borders: `#50485C`
- Main text: `#F6F3FA`
- Muted text: `#B9B2C2`
- Interface font: Poppins (Regular, Medium, SemiBold and Bold), already bundled.
- Rounded controls, restrained gradients and subtle motion.

Include a one-page palette with primary, hover, pressed, disabled and light/dark
logo examples. Avoid relying on color alone to distinguish icon states.

## Optional launch assets

- Wide README header: 1600 × 400 PNG; aim below 500 KB.
- Promo / announcement artwork: 1920 × 1080 PNG or JPG; aim below 1 MB.
- Background concept: 1920 × 1080 reference. Gradients and simple wave patterns
  are preferably recreated in XAML so they scale cleanly without large images.
- App screenshots: 1600 × 1000 or 1920 × 1080 PNG, using fictional messages,
  accounts and credentials.
- Animated logo: optional SVG storyboard or short video reference, with a static
  fallback. Do not make animation necessary for recognizing the brand.

## Smallest useful handoff

Send the **symbol SVG, horizontal-logo SVG, and the palette** first. Include a
white version and a dark version. We can create the ICO, tray exports, app-specific
sizes and UI integration from those files; the launch card can follow afterward.

GitHub's preview requirements and recommendation are documented here:
https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview
