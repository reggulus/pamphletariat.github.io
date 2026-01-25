#!/usr/bin/env python3
import logging
import os
import sys

# ---- silence all logging ----
logging.getLogger().handlers.clear()
logging.basicConfig(level=logging.CRITICAL)

from livereload import Server

DIST_DIR = "dist"

if not os.path.isdir(DIST_DIR):
    sys.exit(1)

server = Server()

# Watch output files only
server.watch("dist/**/*.html")
server.watch("dist/css/**/*")
server.watch("dist/img/**/*")

server.serve(
    root=DIST_DIR,
    host="0.0.0.0",
    port=8000,
    debug=False,
)
