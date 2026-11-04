# The original Xbox core on iOS

Built by `.github/workflows/xemu-ios-core.yml`, separately from the app: it takes
far longer, changes far less often, and is third-party code that has no business
near the signing secrets.

`dukex.pin` is the DukeX commit (GPLv2, xemu fork) the core is built from. It is
the only tree known to run on an M1-class iPad. Xenra's own xemu fork carries
accuracy work this one lacks; moving that across is later work.

Anything in `patches/` is applied on top with `git apply`, in name order.
