# salsabeel-uploader

Updates for the Salsabeel live uploader on the streaming Mac. The source is in the private `salsabeel` repo (`streaming-mac/more/`); these files are a copy of it.

- Once an hour the Mac reads `manifest.txt` from `main`. If its version differs, it downloads `upload-lives.sh` and `status-page.html`, checks each against the SHA-256 in the manifest (and the script with `bash -n`), and switches to them.
- There are no passwords, keys or recordings here.
- To change the Mac: edit `streaming-mac/more/` in `salsabeel`, run `streaming-mac/build.sh`, merge there, then copy the same files here.
