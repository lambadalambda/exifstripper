# Changelog

## 0.1.2

### Added

- Strip GPS data from TIFF files. BigTIFF files are refused with `{:error, :unsupported_bigtiff}`. TIFF files that were passed through unchanged before can now return errors for malformed metadata.

### Fixed

- Support HEIC/ISO-BMFF files whose items use other iloc construction methods, like gridded iPhone photos. These failed with `{:error, :invalid_iloc}`. An `Exif` item that is not stored at a plain file offset now fails with `{:error, :unsupported_exif_location}`.
- Read descriptions from HEIC files with iloc version 1 or 2. GPS stripping and description reading now share one ISO-BMFF parser.
- Bound HEIC iloc parsing by the input size and reject duplicate item ids. Small crafted files could use gigabytes of memory.
- Accept PNG files with data after `IEND`, and drop that data.

## 0.1.1

### Fixed

- Wipe GPS EXIF directories and all referenced out-of-line values (including coordinate rational values and processing-method payloads), not just GPS pointers, in JPEG, WebP and HEIC/ISO-BMFF images. Preserve non-GPS EXIF and container offsets without re-encoding image data; support both TIFF byte orders and prefixed WebP EXIF payloads.
- Return errors for malformed or unsafe TIFF/GPS metadata and invalid HEIC EXIF item tables or overlapping/out-of-bounds physical extents instead of silently returning `:noop`. Malformed metadata leaves the destination unchanged. PNG metadata-chunk removal is unchanged.
- Normalize and validate description candidates before selecting one, restoring IPTC caption fallback when JPEG or PNG EXIF ImageDescription is blank or exceeds `max_length`.
