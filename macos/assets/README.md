# Personal macOS icon

Three concentric usage arcs in teal, blue, and orange, on a satin ceramic tile.
The menu bar retains its live provider and usage indicators. This artwork is the
application icon and appears in the native About window (Actions → About AI Usage Bar).

`AppIcon-source.png` is the original generated artwork with alpha transparency.
`AppIcon.icns` includes Apple's standard 16, 32, 128, 256, and 512 point sizes,
each at 1× and 2×. Rebuild with `./macos/assets/build-icon.sh` on macOS.
The build uses sips for size conversion and iconutil for the ICNS container.

Created using the built-in image generation tool. Design prompt: a centered
macOS continuous rounded-square pale porcelain tile, three thick concentric
partial usage arcs with rounded ends and upper-right gaps, deep ocean teal,
cornflower blue, and warm orange; restrained satin enamel, soft upper-left
lighting, transparent exterior, strong small-size silhouette, no text or logos.

Final extraction prompt:
> Background extraction only. Remove the entire checkerboard background from this icon. Output a PNG with REAL alpha transparency: all pixels outside the rounded ceramic tile must have alpha zero. Do not depict transparency with checkerboard squares or a solid color. Preserve the icon itself exactly, its satin teal blue and orange arcs, ceramic tile and positioning. Clean edge, no speckles outside. Actual transparent cutout deliverable.
