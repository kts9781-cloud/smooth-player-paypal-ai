# Locked libass subprojects

These are the previously resolved dependency versions, retained for the libass
0.17.5 security update: FreeType 2.15.0, FriBidi 1.0.17, HarfBuzz 13.0.1 and
libunibreak 6.1. Both Android and Apple builds consume these tracked wrap files.
Each source/patch has a fixed URL and SHA-256; builds never install today's
wrapdb catalog. Downloaded cache entries are checked before extraction.

libass itself uses the upstream release asset digest from
https://api.github.com/repos/libass/libass/releases/tags/0.17.5:
`libass-0.17.5.tar.xz`, SHA-256
`2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc`.

Android's existing libpng16.a remains a linker input (1.6.55); PNG support in
FreeType is disabled. zlib is supplied by the NDK/Apple SDK, not a bundled
zlib 1.3.2 archive. See ../../LICENSES.md.
