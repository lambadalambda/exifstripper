# ExifStripper

Dependency-free utilities for working with EXIF and related metadata.

Currently provides:

- Lossless GPS stripping (no re-encode) from EXIF and XMP (including DJI drone positions) in JPEG, WebP, PNG, TIFF and ISO-BMFF (HEIC/AVIF). Files are processed without reading the image data into memory.
- Description extraction from common metadata (EXIF/IPTC/XMP)

## Installation

The package can be installed
by adding `exif_stripper` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:exif_stripper, "~> 0.1.2"}
  ]
end
```

## Usage

Strip GPS metadata in-place (returns `:ok`, `:noop` or `{:error, reason}`):

```elixir
ExifStripper.GpsStripper.strip_gps_data("/tmp/in.jpg", "/tmp/in.jpg")
```

Malformed metadata returns an error and leaves the output unchanged.

Read a description:

```elixir
ExifStripper.Description.read_file("/tmp/image.jpg", max_length: 500)
```

## Tests

The test suite uses `exiftool` as an oracle, so `exiftool` must be available in `PATH`.
