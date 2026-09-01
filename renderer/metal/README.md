# Sparse Metal tile backend

`DTMetalTileRenderer.hpp` is the portable-facing boundary.  It describes a
256×256 document tile backed by 258×258 RGBA8 color and R8 coverage textures;
the extra pixel on every side is an apron used for filtering and rotated
sampling.  The header contains no Objective-C or graphics framework types.

`DTMetalTileRenderer.mm` owns Metal objects behind an implementation pointer.
Create it from the iPad bridge with an opaque device handle:

```objc
auto backend = drafting_table::metal::Backend::create((__bridge void *)device);
```

Pass command buffers and drawable textures in the same way.  `encodeDabs`
renders tile-local dab instances twice: premultiplied color with Porter–Duff
OVER, and an independent R8 coverage target with a MAX blend operation.
`encodeApronResolve` pulls interior edge/corner texels from resident neighbors
into each tile's apron. `encodeComposite` draws selected resident tile
interiors through the caller-provided document-to-view transform. A read-only coverage texture can
be obtained as an opaque handle with `nativeCoverageTexture` for hit-testing
or selection passes owned by the caller.

The backend is intentionally a foundation, not a complete document renderer.
The R8 MAX coverage pass is present, but uniform-alpha strokes still require a
separate single-color composite from that mask; the direct color pass is the
normal stacking path. Callers still own page clipping, tile dirtiness,
cross-tile dab expansion, persistence, and command-buffer scheduling. A
positive resident-tile limit fails allocation rather than evicting dirty state
until persistence/restore hooks exist.

Remaining work:

- uniform-alpha coverage-to-color composite
- shade stencil/fill passes
- vector SDF, grid, selection, and page-bound passes
- persisted tile upload/readback and dirty-apron scheduling

Add the `.mm` and `.metal` files to the iPad target when wiring it in; no
Windows build is expected for these Apple-specific sources.
