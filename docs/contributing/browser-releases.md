# Publishing browser releases

The landing page, editor and cached Pocket Studio app ship together. Each release lives under `releases/<manifest-sha256>/` in the editor R2 bucket. A small `editor-release.json` pointer selects the current release. Workspace pages retain their authorized URLs and pin their asset references to that release. Fragment navigation keeps working.

## Prepare and verify

Finish the editor and cached demo builds before packaging:

```sh
bash scripts/build-site.sh
python3 scripts/site_release.py prepare
```

Preparation prints a directory under `bin/site-releases/`. It copies only public site assets, checks native side modules and the prepared demo entry, and hashes every file. Hidden files, symlinks, missing dependencies and changing build inputs are refused. Generated release directories stay outside Git.

```sh
python3 scripts/site_release.py verify bin/site-releases/<release>
```

## Upload, promote and roll back

Use the bucket belonging to the intended environment. These operator commands use the installed Wrangler development dependency and its existing Cloudflare credentials; there is no Node backend service.

```sh
python3 scripts/site_release.py upload bin/site-releases/<release> --bucket rayde-editor-assets-staging
python3 scripts/site_release.py promote bin/site-releases/<release> --bucket rayde-editor-assets-staging
```

Upload leaves the active pointer untouched. Promotion reads back every published file and checks its length and SHA-256 before switching the pointer. An interrupted or corrupt upload cannot be promoted. Roll back by promoting the previous verified release directory with the same command; retain its R2 objects so existing pages continue using their pinned assets.

The Rust Worker must include release routing before promotion. Without a pointer, existing mutable editor paths remain available. A malformed or incomplete pointer fails closed. Pages and the pointer are uncached; versioned binary, module, font and image responses are immutable. WASM streams directly from R2.

For a separate landing hostname, configure `LANDING_ORIGIN` and its Worker custom domain. Keep `APP_ORIGIN`, `ASSETS_ORIGIN` and `PREVIEW_ORIGIN` distinct and use separate staging and production resources. Landing and editor responses carry COOP/COEP; public assets carry CORP/CORS and their correct MIME types. Cached app previews are served only through the preview origin's demo paths.

Packaging does not provision anonymous demo compute. The public landing still needs isolated visitor admission for Rayzor and extensions; never expose a loopback `--preview-project` token as a shared public session.

## Checks

```sh
python3 -m unittest discover -s tests -p site_release_test.py
cd web/cloud
node --test test/assets.test.mjs
```

Build the Rust Worker before its gateway tests. The checks cover interrupted upload, corruption, rollback, old pages across promotion, streamed WASM, isolation headers and workspace authorization. Browser acceptance remains part of staging promotion.
