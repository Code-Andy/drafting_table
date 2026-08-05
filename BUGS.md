List of bugs and their status:

- Loss of sharpness when select + dragging raster content. FIXED — validated on device.
  Cause: a move drag left the floating selection's centre at a fractional doc-px
  offset, and `commitRasterSelectionImpl` bakes the content texture with
  GL_LINEAR — so every destination pixel became a 2x2 blend of its neighbours,
  a permanent one-pixel blur that compounded on each lift/drop cycle.
  Fix: snap an unrotated placement to the doc-pixel grid before the bake, and
  sample NEAREST when the placement is also unscaled (1:1 texel copy).
  Rotated/scaled placements still resample, which is inherent.

- Transform bugs: when selecting and moving a region, sometimes when I tap outside the selected region to finalize the movement, the region instead scales one corner to the tap location. FIXED — validated on device.
  Cause: `hitTestRasterSelectionHandle` runs on the UI thread but sized its
  18-view-px handle radius via `currentViewScale()`, which `renderPageThumbnail`
  temporarily overwrites with the thumbnail scale (~0.05) on the GL thread. A
  tap dispatched inside that window saw a ~350 doc-px corner radius. Hence
  "sometimes" — thumbnails re-render on every quiet frame with the sidebar open.
  The scale drag also recorded no grab offset, so the corner teleported to the
  pen rather than moving with it.
  Fix: hit-tests now use `userViewScale()` via `vpxToDocUi` (the same mirror the
  snap code already uses); `DragState.grabOffsetX/Y` keeps the grabbed corner
  under the pen; and the touch handler adds a 6-view-px drag slop plus
  "unmoved tap outside the body on a corner handle = finalize".

- Slow to switch between documents - several seconds of loading. When switching b/w docs, remember the last page the doc was viewed on instead of opening on the first page. FIXED (improved) — validated on device.
  Cause: opening a document eagerly loaded EVERY page's tiles (256 KB read +
  texture + FBO each) synchronously on the GL thread.
  Fix: `Page::contentLoaded` + `ensurePageContentLoaded` — metadata for all
  pages, content only for the active one, others on demand (page switch,
  thumbnail, export). The sidebar's full thumbnail refresh is now spread over
  several frames instead of pulling in every page at once.
  Last page is persisted per document in `<docDir>/active_page.txt`.
  Still somewhat slower than desired — see "Deferred" below.

- Page previews flash when selecting a different page in the sidebar. FIXED — validated on device.
  Regression from the lazy-page-load work. `onThumbnailsUpdated` called
  `rebuildSidebar()` on any active-page change; that allocates a fresh white
  Bitmap per item and re-registers them as thumbnail targets, so every preview
  blanked and repainted. Invisible while the whole refresh ran in one GL pass;
  visible once it was spread across several.
  Fix: only rebuild when the page COUNT changes. A page switch takes
  `updateSidebarActivePage`, which just moves the highlight across the existing
  items — no view-tree churn, no bitmap reallocation.

---

## Deferred

- **Disk-cached page thumbnails** — the remaining lever on document-switch time.
  Not currently annoying enough to justify; revisit if it keeps grating.

  Problem: the page sidebar is what still forces every page's tiles into memory
  after a document switch. `renderPageThumbnail` composites a *real* page, so
  refreshing all thumbnails walks the whole document. The per-frame throttle
  (`thumbnailRefreshQueue`, DrawingSurfaceView) turned that from a multi-second
  freeze into background streaming, but the I/O still happens.

  Proposed fix: persist each page's thumbnail to `<docDir>/page_<n>/thumb.bin`
  (raw RGBA at the sidebar's thumb dimensions, plus a small header for
  dimensions). The sidebar populates from the cache without loading page
  content at all, so a document switch loads exactly one page's tiles.

  Invalidation is the design work:
  - Rewrite a page's cache after its content changes — the trailing-edge quiet
    frame that already re-renders the active thumbnail is the natural hook.
  - Thumb dimensions depend on canvas aspect (`thumbDimensions()`); a cache
    whose header doesn't match the current dimensions must be discarded.
  - `deletePageImpl` / `movePageImpl` renumber page dirs, so the cache files
    travel with their directories for free.
  - Undo/redo affects the active page only, which is already refreshed live.

  Cost: a new on-disk artifact per page (~a few KB each) and the invalidation
  rules above. Worth it only if the streaming-in stays noticeable.
