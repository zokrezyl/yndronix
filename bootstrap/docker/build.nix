# Compatibility entrypoint for build-tools/build-package and the service-bundle
# closure step, which invoke
#   nix-build bootstrap/docker/build.nix --argstr attr <attr> --arg android <bool>
# and expect a SINGLE derivation back.
#
# The package set now lives in the modular nix/ tree (see nix/README.md); this
# file just maps the (attr, android) call convention onto nix/default.nix's
# `resolve`. nix/nixpkgs.nix carries the pinned nixpkgs revision.
{ attr, android ? false }:
(import ../../nix { inherit android; }).resolve attr
