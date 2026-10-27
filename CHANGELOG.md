# Changelog

## 0.1.3 (unreleased)

### Added

- Strip GPS properties from XMP: JPEG (XMP and Extended XMP segments), WebP (`XMP ` chunk), HEIC/AVIF (`application/rdf+xml` items) and TIFF (tag 700). GPS properties are the elements and attributes in the EXIF namespace whose names start with `GPS`. They are overwritten with spaces, so offsets do not change and the XMP stays well-formed. XMP that cannot be scanned safely (DTDs, unbalanced tags, UTF-16, encoded HEIC items, incomplete Extended XMP) returns an error, so files that passed before can now fail. PNG files already lost their XMP with the `iTXt` chunk.
- `Description` reads TIFF files: IFD0 `ImageDescription`, with the IPTC caption (tag 33723) as fallback. BigTIFF files return `nil`.

### Changed

- `strip_gps_data/2` no longer reads the whole file into memory. It reads only the metadata, and patches the file in place when input and output are the same file. Peak memory for a 20 MB JPEG or PNG went from 40-60 MB to about 1 MB. PNG files, and outputs that are other files, are written to a temporary file next to the output and then renamed over it, so this needs write access to the output directory.
- Metadata that must be loaded into memory (ISO-BMFF `meta` boxes and Exif items) is limited to 16 MiB. Larger metadata returns `{:error, :metadata_too_large}`.
- JPEG fill bytes (`FF FF`) before a marker are kept. Before, one byte per pair was dropped.

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
