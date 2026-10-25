# Changelog

## 0.1.1

### Fixed

- Wipe GPS EXIF directories and all referenced out-of-line values (including coordinate rational values and processing-method payloads), not just GPS pointers, in JPEG, WebP and HEIC/ISO-BMFF images. Preserve non-GPS EXIF and container offsets without re-encoding image data; support both TIFF byte orders and prefixed WebP EXIF payloads.
- Return errors for malformed or unsafe TIFF/GPS metadata and invalid HEIC EXIF item tables or overlapping/out-of-bounds physical extents instead of silently returning `:noop`. Malformed metadata leaves the destination unchanged. PNG metadata-chunk removal is unchanged.
- Normalize and validate description candidates before selecting one, restoring IPTC caption fallback when JPEG or PNG EXIF ImageDescription is blank or exceeds `max_length`.
