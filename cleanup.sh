#!/bin/bash

echo "Cleaning up temporary files generated during the Zig 0.16.0 update..."

# Remove temporary test code
rm -f test_bs.zig

# Remove temporary Python patch scripts
rm -f patch_user.py
rm -f fix_ptrs.py
rm -f rename_entry.py
rm -f patch_const.py
rm -f fix_all.py

# Remove all log files
find . -name "*.log" -type f -delete

# Remove patch reject files
rm -f src/user/storaged.zig.rej

echo "Cleanup complete!"
