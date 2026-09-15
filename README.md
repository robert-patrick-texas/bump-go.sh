# bump-go.sh
Bump-Go is a Bash script that bootstraps and updates the Go runtime environment for use on Linux hosts.

Documentation comments within the script as general description are listed below:

```
 Purpose:
   - Ensure Go is installed under /usr/local/go
   - If Go already exists, update it to the latest stable release
   - Verify the downloaded archive against Go's published SHA-256
     checksum before anything is installed

 Usage:
   sudo ./bump-go.sh [OPTIONS]

   Root privileges are required because installation targets
   /usr/local/go. If not run as root, the script re-invokes the
   privileged install/remove steps individually via sudo.

 Options:
   --dry-run
       Show what would be done without making changes.
   --force-reinstall
       Remove and reinstall the latest Go release even if the
       currently installed version is already up to date.
   -h, --help
       Show usage information.

 Notes:
   - Official Go install layout: https://go.dev/doc/install
   - Upstream guidance is to remove any previous /usr/local/go
     tree before extracting a new one, which is what this script
     does for both the update and force-reinstall flows:
       sudo rm -rf /usr/local/go
       sudo tar -C /usr/local -xzf go<version>.<os>-<arch>.tar.gz
   - Latest version is discovered via https://go.dev/VERSION?m=text
   - Checksums are fetched from https://dl.google.com/go/<archive>.sha256
   - PATH is exposed to all users via /etc/profile.d/go.sh so that
     /usr/local/go/bin is available after a fresh login shell.
```
